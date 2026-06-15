param(
    [string]$BizHawkPath = $env:BIZHAWK_PATH,
    [switch]$NoDownload,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.Windows.Forms

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRomName = "Zombies Ate My Neighbors (USA).sfc"
$PatchedRomName = "Zombies Ate My Neighbors DX.sfc"
$SourceRom = Join-Path $Root $SourceRomName
$PatchedRom = Join-Path $Root "dist\$PatchedRomName"
$IpsPath = Join-Path $Root "dist\zamndx.ips"
$LuaPath = Join-Path $Root "mod\zamndx.lua"
$BizHawkInstall = Join-Path $env:LOCALAPPDATA "ZAMNDX\BizHawk"

$ExpectedSourceHash = "B27E2E957FA760F4F483E2AF30E03062034A6C0066984F2E284CC2CB430B2059"
$ExpectedPatchedHash = "4B544A574C3D3D41171CD4F96DBA32B3BC694EACC561ADAB33212A4958DDB85B"

function Show-Error([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        "ZAMN DX Launcher",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Select-SourceRom {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select the headerless USA Zombies Ate My Neighbors ROM"
    $dialog.Filter = "SNES ROM (*.sfc;*.smc)|*.sfc;*.smc|All files (*.*)|*.*"
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "A compatible source ROM is required."
    }
    return $dialog.FileName
}

function Apply-IpsPatch([string]$RomPath, [string]$PatchPath, [string]$OutputPath) {
    $rom = [System.Collections.Generic.List[byte]]::new()
    $rom.AddRange([byte[]][System.IO.File]::ReadAllBytes($RomPath))
    $patch = [System.IO.File]::ReadAllBytes($PatchPath)

    if ($patch.Length -lt 8 -or [System.Text.Encoding]::ASCII.GetString($patch, 0, 5) -ne "PATCH") {
        throw "The bundled IPS patch is invalid."
    }

    $position = 5
    while ($position + 3 -le $patch.Length) {
        if ([System.Text.Encoding]::ASCII.GetString($patch, $position, 3) -eq "EOF") {
            break
        }

        $offset = (
            (([int]$patch[$position]) -shl 16) -bor
            (([int]$patch[$position + 1]) -shl 8) -bor
            ([int]$patch[$position + 2])
        )
        $position += 3

        $size = ($patch[$position] -shl 8) -bor $patch[$position + 1]
        $position += 2

        if ($size -eq 0) {
            $size = ($patch[$position] -shl 8) -bor $patch[$position + 1]
            $value = $patch[$position + 2]
            $position += 3
            $replacement = [byte[]]::new($size)
            for ($index = 0; $index -lt $size; $index++) {
                $replacement[$index] = $value
            }
        } else {
            if ($position + $size -gt $patch.Length) {
                throw "The bundled IPS patch ends unexpectedly."
            }
            $replacement = [byte[]]::new($size)
            [Array]::Copy($patch, $position, $replacement, 0, $size)
            $position += $size
        }

        $requiredLength = $offset + $size
        while ($rom.Count -lt $requiredLength) {
            $rom.Add(0)
        }
        for ($index = 0; $index -lt $size; $index++) {
            $rom[$offset + $index] = $replacement[$index]
        }
    }

    $outputDirectory = Split-Path -Parent $OutputPath
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    [System.IO.File]::WriteAllBytes($OutputPath, $rom.ToArray())
}

function Ensure-PatchedRom {
    if ((Test-Path -LiteralPath $PatchedRom) -and
        (Get-Sha256 $PatchedRom) -eq $ExpectedPatchedHash) {
        return
    }

    $selectedSource = $SourceRom
    if (-not (Test-Path -LiteralPath $selectedSource)) {
        $selectedSource = Select-SourceRom
    }

    $actualHash = Get-Sha256 $selectedSource
    if ($actualHash -ne $ExpectedSourceHash) {
        throw @"
This is not the supported headerless USA ROM.

Expected SHA-256:
$ExpectedSourceHash

Selected ROM SHA-256:
$actualHash
"@
    }

    Write-Host "Building $PatchedRomName..."
    Apply-IpsPatch $selectedSource $IpsPath $PatchedRom

    $patchedHash = Get-Sha256 $PatchedRom
    if ($patchedHash -ne $ExpectedPatchedHash) {
        throw "The patched ROM failed verification. Expected $ExpectedPatchedHash, got $patchedHash."
    }
}

function Find-BizHawk {
    $candidates = @(
        $BizHawkPath,
        (Join-Path $BizHawkInstall "EmuHawk.exe"),
        (Join-Path $Root "BizHawk\EmuHawk.exe"),
        (Join-Path $Root "EmuHawk.exe")
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $nested = Join-Path $candidate "EmuHawk.exe"
            if (Test-Path -LiteralPath $nested -PathType Leaf) {
                return (Resolve-Path -LiteralPath $nested).Path
            }
        }
    }
    return $null
}

function Install-BizHawk {
    if ($NoDownload) {
        throw "BizHawk was not found. Set BIZHAWK_PATH or remove the -NoDownload option."
    }

    $choice = [System.Windows.Forms.MessageBox]::Show(
        "BizHawk was not found. Download the latest official Windows release now?",
        "ZAMN DX Launcher",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        throw "BizHawk is required to play with analog and twin-stick controls."
    }

    Write-Host "Finding the latest official BizHawk release..."
    $headers = @{ "User-Agent" = "ZAMNDX-Launcher" }
    $release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/TASEmulators/BizHawk/releases/latest" `
        -Headers $headers
    $asset = $release.assets |
        Where-Object { $_.name -match "BizHawk-.*-win-x64\.zip$" } |
        Select-Object -First 1
    if (-not $asset) {
        throw "The latest BizHawk release has no Windows x64 archive."
    }

    $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "zamndx-bizhawk"
    $zipPath = Join-Path $tempDirectory $asset.name
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    [System.IO.Directory]::CreateDirectory($tempDirectory) | Out-Null

    try {
        Write-Host "Downloading BizHawk $($release.tag_name)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers

        Remove-Item -LiteralPath $BizHawkInstall -Recurse -Force -ErrorAction SilentlyContinue
        [System.IO.Directory]::CreateDirectory($BizHawkInstall) | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $BizHawkInstall -Force
    } finally {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    $emulator = Find-BizHawk
    if (-not $emulator) {
        throw "BizHawk downloaded, but EmuHawk.exe could not be found."
    }
    return $emulator
}

try {
    $host.UI.RawUI.WindowTitle = "Zombies Ate My Neighbors DX Launcher"

    if (-not (Test-Path -LiteralPath $IpsPath)) {
        throw "Missing patch: $IpsPath"
    }
    if (-not (Test-Path -LiteralPath $LuaPath)) {
        throw "Missing controller script: $LuaPath"
    }

    Ensure-PatchedRom

    $emulator = Find-BizHawk
    if (-not $emulator) {
        $emulator = Install-BizHawk
    }

    if ($NoLaunch) {
        Write-Host "Launcher check passed."
        Write-Host "ROM: $PatchedRom"
        Write-Host "BizHawk: $emulator"
        exit 0
    }

    Write-Host "Starting Zombies Ate My Neighbors DX..."
    $arguments = @(
        "--gdi",
        "--lua",
        "`"$LuaPath`"",
        "`"$PatchedRom`""
    )
    Start-Process `
        -FilePath $emulator `
        -WorkingDirectory (Split-Path -Parent $emulator) `
        -ArgumentList $arguments
} catch {
    $message = $_.Exception.Message
    Write-Error $message
    Show-Error $message
    exit 1
}
