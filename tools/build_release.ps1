param(
    [string]$Version = "1.0.0",
    [string]$DotnetVersion = "8.0.422",
    [string]$BizHawkVersion = "2.11.1",
    [string]$VcRuntimeDirectory,
    [string]$SigningCertificateThumbprint,
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

[System.IO.Directory]::CreateDirectory($ToolsDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($DownloadsDirectory) | Out-Null

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

& $Dotnet run --project $TestProject -c Release
if ($LASTEXITCODE -ne 0) {
    throw "The launcher tests failed."
}

& $Dotnet publish $Project `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:Version=$Version `
    -p:PublishSingleFile=true
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
Copy-Item -LiteralPath (Join-Path $Root "README.md") -Destination (Join-Path $StageDirectory "README.md")

$stagedLauncher = Join-Path $StageDirectory "ZAMN-DX.exe"
$signatureStatus = "NotSigned"
if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
    $certificate = Get-ChildItem "Cert:\CurrentUser\My\$SigningCertificateThumbprint" -ErrorAction Stop
    $signature = Set-AuthenticodeSignature `
        -FilePath $stagedLauncher `
        -Certificate $certificate `
        -TimestampServer "http://timestamp.digicert.com" `
        -HashAlgorithm SHA256
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Authenticode signing failed: $($signature.StatusMessage)"
    }
    $signatureStatus = $signature.Status.ToString()
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
    patch_sha256 = (Get-FileHash -LiteralPath (Join-Path $StageDirectory "mod\zamndx.ips") -Algorithm SHA256).Hash
    lua_sha256 = (Get-FileHash -LiteralPath (Join-Path $StageDirectory "mod\zamndx.lua") -Algorithm SHA256).Hash
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
    expected_patched_rom_sha256 = "4B544A574C3D3D41171CD4F96DBA32B3BC694EACC561ADAB33212A4958DDB85B"
    generated_utc = [DateTime]::UtcNow.ToString("o")
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $StageDirectory "release-manifest.json") -Encoding UTF8

$checksums = @(
    "$($manifest.launcher_sha256)  ZAMN-DX.exe"
    "$($manifest.patch_sha256)  mod/zamndx.ips"
    "$($manifest.lua_sha256)  mod/zamndx.lua"
)
$checksums | Set-Content -LiteralPath (Join-Path $StageDirectory "SHA256SUMS.txt") -Encoding ASCII

if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}
Compress-Archive -LiteralPath $StageDirectory -DestinationPath $ZipPath -CompressionLevel Optimal

$zip = Get-Item -LiteralPath $ZipPath
$hash = Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
Write-Host "Release: $($zip.FullName)"
Write-Host "Size: $([Math]::Round($zip.Length / 1MB, 1)) MiB"
Write-Host "SHA-256: $($hash.Hash)"
