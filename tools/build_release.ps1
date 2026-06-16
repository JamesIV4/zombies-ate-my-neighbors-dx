param(
    [string]$Version = "1.0.0",
    [string]$DotnetVersion = "8.0.422",
    [string]$BizHawkVersion = "2.11.1",
    [string]$VcRuntimeDirectory,
    [string]$SigningCertificateThumbprint,
    [string]$TimestampServer = "http://timestamp.digicert.com",
    [int]$SigningTimeoutSeconds = 120,
    [switch]$RequireSignature,
    [switch]$SkipTimestamp,
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ToolsDirectory = Join-Path $Root ".tools"
$DotnetDirectory = Join-Path $ToolsDirectory "dotnet"
$Dotnet = Join-Path $DotnetDirectory "dotnet.exe"
$DownloadsDirectory = Join-Path $ToolsDirectory "downloads"
$BizHawkZip = Join-Path $DownloadsDirectory "BizHawk-$BizHawkVersion-win-x64.zip"
$Project = Join-Path $Root "launcher\ZamndxLauncher\ZamndxLauncher.csproj"
$TestProject = Join-Path $Root "launcher\ZamndxLauncher.Tests\ZamndxLauncher.Tests.csproj"
$PublishDirectory = Join-Path $Root "launcher\ZamndxLauncher\bin\Release\net8.0-windows\win-x64\publish"
$StageDirectory = Join-Path $Root "dist\release\ZAMN-DX-Windows-x64"
$ZipPath = Join-Path $Root "dist\ZAMN-DX-Windows-x64-v$Version.zip"
$ZipChecksumPath = "$ZipPath.sha256"
$RomBuildScript = Join-Path $Root "tools\build.py"
$SourceRom = Join-Path $Root "Zombies Ate My Neighbors (USA).sfc"
$PatchedRom = Join-Path $Root "dist\Zombies Ate My Neighbors DX.sfc"
$IpsPatch = Join-Path $Root "dist\zamndx.ips"

[System.IO.Directory]::CreateDirectory($ToolsDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($DownloadsDirectory) | Out-Null

if (-not (Test-Path -LiteralPath $SourceRom)) {
    throw @"
The source ROM is required to rebuild the IPS patch:

  $SourceRom
"@
}

$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) {
    throw "Python 3 is required to rebuild the ROM patch."
}

Write-Host "Rebuilding ROM patch..."
& $python.Source $RomBuildScript `
    $SourceRom `
    --output $PatchedRom `
    --ips $IpsPatch
if ($LASTEXITCODE -ne 0) {
    throw "The ROM patch build failed."
}
$PatchedRomHash = (Get-FileHash -LiteralPath $PatchedRom -Algorithm SHA256).Hash

if (-not (Test-Path -LiteralPath $Dotnet)) {
    if ($SkipDownload) {
        throw "The portable .NET SDK is missing: $Dotnet"
    }

    $installScript = Join-Path $DownloadsDirectory "dotnet-install.ps1"
    Invoke-WebRequest "https://dot.net/v1/dotnet-install.ps1" -OutFile $installScript
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript `
        -Version $DotnetVersion `
        -Architecture x64 `
        -InstallDir $DotnetDirectory `
        -NoPath
    if ($LASTEXITCODE -ne 0) {
        throw "The portable .NET SDK installation failed."
    }
}

if (-not (Test-Path -LiteralPath $BizHawkZip)) {
    if ($SkipDownload) {
        throw "The BizHawk archive is missing: $BizHawkZip"
    }

    $uri = "https://github.com/TASEmulators/BizHawk/releases/download/$BizHawkVersion/BizHawk-$BizHawkVersion-win-x64.zip"
    Invoke-WebRequest $uri -OutFile $BizHawkZip
}

Write-Host "Running launcher tests..."
try {
    $env:ZAMNDX_EXPECTED_PATCHED_ROM_HASH = $PatchedRomHash
    & $Dotnet run `
        --project $TestProject `
        -c Release `
        "-p:ExpectedPatchedRomHash=$PatchedRomHash"
    if ($LASTEXITCODE -ne 0) {
        throw "The launcher tests failed."
    }
} finally {
    Remove-Item Env:\ZAMNDX_EXPECTED_PATCHED_ROM_HASH -ErrorAction SilentlyContinue
}

Write-Host "Publishing self-contained C# launcher..."
& $Dotnet publish $Project `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:Version=$Version `
    -p:PublishSingleFile=true `
    "-p:ExpectedPatchedRomHash=$PatchedRomHash"
if ($LASTEXITCODE -ne 0) {
    throw "The launcher publish failed."
}

if (Test-Path -LiteralPath $StageDirectory) {
    Remove-Item -LiteralPath $StageDirectory -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($StageDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $StageDirectory "mod")) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $StageDirectory "runtime\BizHawk")) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $StageDirectory "licenses")) | Out-Null

Copy-Item -LiteralPath (Join-Path $PublishDirectory "ZAMN-DX.exe") -Destination $StageDirectory
Copy-Item -LiteralPath (Join-Path $Root "dist\zamndx.ips") -Destination (Join-Path $StageDirectory "mod\zamndx.ips")
Copy-Item -LiteralPath (Join-Path $Root "mod\zamndx.lua") -Destination (Join-Path $StageDirectory "mod\zamndx.lua")
Copy-Item -LiteralPath (Join-Path $Root "mod\bloody-disgusting.ips") -Destination (Join-Path $StageDirectory "mod\bloody-disgusting.ips")
Copy-Item -LiteralPath (Join-Path $Root "mod\bloody-disgusting.txt") -Destination (Join-Path $StageDirectory "mod\bloody-disgusting.txt")
Copy-Item -LiteralPath (Join-Path $Root "mod\reverse-inventory-cycling.ips") -Destination (Join-Path $StageDirectory "mod\reverse-inventory-cycling.ips")
Copy-Item -LiteralPath (Join-Path $Root "mod\reverse-inventory-cycling.txt") -Destination (Join-Path $StageDirectory "mod\reverse-inventory-cycling.txt")
Copy-Item -LiteralPath (Join-Path $Root "README.md") -Destination (Join-Path $StageDirectory "README.md")

$stagedLauncher = Join-Path $StageDirectory "ZAMN-DX.exe"
$signatureStatus = "NotSigned"
$signingCertificate = $null
if ($RequireSignature -and [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
    throw "A code-signing certificate is required for this release."
}
if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
    $SigningCertificateThumbprint = $SigningCertificateThumbprint.Replace(" ", "").ToUpperInvariant()
    $signingCertificate = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
        Where-Object {
            $_.Thumbprint -eq $SigningCertificateThumbprint -and
            $_.HasPrivateKey -and
            $_.NotBefore -le (Get-Date) -and
            $_.NotAfter -gt (Get-Date)
        } |
        Select-Object -First 1
    if ($null -eq $signingCertificate) {
        throw "The configured code-signing certificate is missing, expired, or has no private key."
    }

    Write-Host "Signing launcher with $($signingCertificate.Subject)..."
    $signingJob = Start-Job -ScriptBlock {
        param($FilePath, $Thumbprint, $TimestampUrl, $WithoutTimestamp)

        $certificate = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
            Where-Object Thumbprint -eq $Thumbprint |
            Select-Object -First 1
        if ($null -eq $certificate) {
            throw "The signing worker could not load the configured certificate."
        }

        $parameters = @{
            FilePath = $FilePath
            Certificate = $certificate
            IncludeChain = "All"
            HashAlgorithm = "SHA256"
        }
        if (-not $WithoutTimestamp) {
            $parameters.TimestampServer = $TimestampUrl
        }
        $signature = Set-AuthenticodeSignature @parameters
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "Authenticode signing failed: $($signature.StatusMessage)"
        }
    } -ArgumentList $stagedLauncher, $SigningCertificateThumbprint, $TimestampServer, $SkipTimestamp.IsPresent

    try {
        if ($null -eq (Wait-Job -Job $signingJob -Timeout $SigningTimeoutSeconds)) {
            Stop-Job -Job $signingJob
            throw "Authenticode signing timed out after $SigningTimeoutSeconds seconds."
        }
        Receive-Job -Job $signingJob -ErrorAction Stop
        if ($signingJob.State -ne "Completed") {
            throw "Authenticode signing failed in the signing worker."
        }
    } finally {
        Remove-Job -Job $signingJob -Force -ErrorAction SilentlyContinue
    }

    $verifiedSignature = Get-AuthenticodeSignature -LiteralPath $stagedLauncher
    if ($verifiedSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $verifiedSignature.SignerCertificate.Thumbprint -ne $SigningCertificateThumbprint) {
        throw "The signed launcher failed Authenticode verification."
    }
    $signatureStatus = $verifiedSignature.Status.ToString()
}

Expand-Archive -LiteralPath $BizHawkZip -DestinationPath (Join-Path $StageDirectory "runtime\BizHawk") -Force

if ([string]::IsNullOrWhiteSpace($VcRuntimeDirectory)) {
    $vcCandidates = @()
    foreach ($programFilesRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($programFilesRoot)) {
            continue
        }
        $vcCandidates += Get-ChildItem `
            -Path "$programFilesRoot\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT" `
            -Directory `
            -ErrorAction SilentlyContinue
    }
    $VcRuntimeDirectory = $vcCandidates |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

if ([string]::IsNullOrWhiteSpace($VcRuntimeDirectory) -or
    -not (Test-Path -LiteralPath (Join-Path $VcRuntimeDirectory "vcruntime140.dll"))) {
    throw @"
The Microsoft Visual C++ x64 app-local runtime could not be found.
Install Visual Studio Build Tools with the C++ workload, or pass:

  -VcRuntimeDirectory "path\to\x64\Microsoft.VC*.CRT"
"@
}

$bizHawkDirectory = Join-Path $StageDirectory "runtime\BizHawk"
Copy-Item -Path (Join-Path $VcRuntimeDirectory "*.dll") -Destination $bizHawkDirectory -Force

$bizHawkLicenseUri = "https://raw.githubusercontent.com/TASEmulators/BizHawk/$BizHawkVersion/LICENSE"
Invoke-WebRequest $bizHawkLicenseUri -OutFile (Join-Path $StageDirectory "licenses\BizHawk-LICENSE.txt")

foreach ($name in @("LICENSE.txt", "ThirdPartyNotices.txt")) {
    $source = Join-Path $DotnetDirectory $name
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $StageDirectory "licenses\.NET-$name")
    }
}

$vcRuntimeNotice = @"
Microsoft Visual C++ Runtime
============================

This distribution includes the x64 app-local Microsoft Visual C++ runtime
files from:

$VcRuntimeDirectory

Microsoft documentation:
https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files

These files are included beside BizHawk so players do not need to install the
Microsoft Visual C++ Redistributable separately.
"@
$vcRuntimeNotice | Set-Content `
    -LiteralPath (Join-Path $StageDirectory "licenses\Microsoft-Visual-Cpp-Runtime.txt") `
    -Encoding UTF8

$releaseReadme = @"
ZOMBIES ATE MY NEIGHBORS DX
===========================

1. Extract this ZIP to a normal folder.
2. Run ZAMN-DX.exe.
3. Choose Configure Controller if desired.
4. Choose Play Game.
5. On the first launch only, select your legally obtained headerless USA ROM.

No emulator, scripting runtime, Python installation, or setup process is required.
The original commercial game ROM is not included.

Expected source ROM SHA-256:
B27E2E957FA760F4F483E2AF30E03062034A6C0066984F2E284CC2CB430B2059

The launcher stores its generated patched ROM and user settings under:
%LOCALAPPDATA%\ZAMNDX

Third-party license notices are in the licenses folder.
"@
$releaseReadme | Set-Content -LiteralPath (Join-Path $StageDirectory "START HERE.txt") -Encoding UTF8

$manifest = [ordered]@{
    product = "Zombies Ate My Neighbors DX"
    version = $Version
    architecture = "win-x64"
    launcher_sha256 = (Get-FileHash -LiteralPath $stagedLauncher -Algorithm SHA256).Hash
    launcher_signature = $signatureStatus
    signing_certificate_thumbprint = if ($null -ne $signingCertificate) { $signingCertificate.Thumbprint } else { $null }
    signing_certificate_subject = if ($null -ne $signingCertificate) { $signingCertificate.Subject } else { $null }
    signing_certificate_expires = if ($null -ne $signingCertificate) { $signingCertificate.NotAfter.ToUniversalTime().ToString("o") } else { $null }
    timestamp_server = if ($null -ne $signingCertificate -and -not $SkipTimestamp) { $TimestampServer } else { $null }
    patch_sha256 = (Get-FileHash -LiteralPath (Join-Path $StageDirectory "mod\zamndx.ips") -Algorithm SHA256).Hash
    lua_sha256 = (Get-FileHash -LiteralPath (Join-Path $StageDirectory "mod\zamndx.lua") -Algorithm SHA256).Hash
    optional_patches = @(
        [ordered]@{
            id = "bloody"
            file = "mod/bloody-disgusting.ips"
            sha256 = (Get-FileHash -LiteralPath (Join-Path $StageDirectory "mod\bloody-disgusting.ips") -Algorithm SHA256).Hash
        }
        [ordered]@{
            id = "reverse-cycling"
            file = "mod/reverse-inventory-cycling.ips"
            sha256 = (Get-FileHash -LiteralPath (Join-Path $StageDirectory "mod\reverse-inventory-cycling.ips") -Algorithm SHA256).Hash
        }
    )
    bizhawk_version = $BizHawkVersion
    bizhawk_archive_sha256 = (Get-FileHash -LiteralPath $BizHawkZip -Algorithm SHA256).Hash
    bizhawk_download = "https://github.com/TASEmulators/BizHawk/releases/download/$BizHawkVersion/BizHawk-$BizHawkVersion-win-x64.zip"
    visual_cpp_runtime_version = (Get-Item (Join-Path $bizHawkDirectory "vcruntime140.dll")).VersionInfo.FileVersion
    visual_cpp_runtime_files = @(
        Get-ChildItem -LiteralPath $VcRuntimeDirectory -Filter "*.dll" |
            Sort-Object Name |
            ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    sha256 = (Get-FileHash -LiteralPath (Join-Path $bizHawkDirectory $_.Name) -Algorithm SHA256).Hash
                }
            }
    )
    dotnet_sdk_version = $DotnetVersion
    expected_source_rom_sha256 = "B27E2E957FA760F4F483E2AF30E03062034A6C0066984F2E284CC2CB430B2059"
    expected_patched_rom_sha256 = $PatchedRomHash
    generated_utc = [DateTime]::UtcNow.ToString("o")
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $StageDirectory "release-manifest.json") -Encoding UTF8

$checksums = @(
    "$($manifest.launcher_sha256)  ZAMN-DX.exe"
    "$($manifest.patch_sha256)  mod/zamndx.ips"
    "$($manifest.lua_sha256)  mod/zamndx.lua"
    "$($manifest.optional_patches[0].sha256)  mod/bloody-disgusting.ips"
    "$($manifest.optional_patches[1].sha256)  mod/reverse-inventory-cycling.ips"
)
$checksums | Set-Content -LiteralPath (Join-Path $StageDirectory "SHA256SUMS.txt") -Encoding ASCII

if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}
if (Test-Path -LiteralPath $ZipChecksumPath) {
    Remove-Item -LiteralPath $ZipChecksumPath -Force
}
Compress-Archive -LiteralPath $StageDirectory -DestinationPath $ZipPath -CompressionLevel Optimal

$zip = Get-Item -LiteralPath $ZipPath
$hash = Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
"$($hash.Hash)  $($zip.Name)" | Set-Content -LiteralPath $ZipChecksumPath -Encoding ASCII
Write-Host "Release: $($zip.FullName)"
Write-Host "Size: $([Math]::Round($zip.Length / 1MB, 1)) MiB"
Write-Host "SHA-256: $($hash.Hash)"
Write-Host "Checksum: $ZipChecksumPath"
Write-Host "Launcher signature: $signatureStatus"
