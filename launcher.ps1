param(
    [string]$BizHawkPath = $env:BIZHAWK_PATH,
    [switch]$NoDownload,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Zamndx
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Gamepad
    {
        public ushort Buttons;
        public byte LeftTrigger;
        public byte RightTrigger;
        public short LeftThumbX;
        public short LeftThumbY;
        public short RightThumbX;
        public short RightThumbY;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NativeState
    {
        public uint PacketNumber;
        public Gamepad Gamepad;
    }

    public struct ControllerState
    {
        public bool Connected;
        public uint PacketNumber;
        public ushort Buttons;
        public byte LeftTrigger;
        public byte RightTrigger;
        public short LeftThumbX;
        public short LeftThumbY;
        public short RightThumbX;
        public short RightThumbY;
    }

    public static class XInput
    {
        [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")]
        private static extern uint GetState14(uint userIndex, out NativeState state);

        [DllImport("xinput9_1_0.dll", EntryPoint = "XInputGetState")]
        private static extern uint GetState910(uint userIndex, out NativeState state);

        public static ControllerState Read(int slot)
        {
            NativeState native;
            uint result;
            try
            {
                result = GetState14((uint)slot, out native);
            }
            catch (DllNotFoundException)
            {
                result = GetState910((uint)slot, out native);
            }

            ControllerState state = new ControllerState();
            state.Connected = result == 0;
            if (!state.Connected) return state;

            state.PacketNumber = native.PacketNumber;
            state.Buttons = native.Gamepad.Buttons;
            state.LeftTrigger = native.Gamepad.LeftTrigger;
            state.RightTrigger = native.Gamepad.RightTrigger;
            state.LeftThumbX = native.Gamepad.LeftThumbX;
            state.LeftThumbY = native.Gamepad.LeftThumbY;
            state.RightThumbX = native.Gamepad.RightThumbX;
            state.RightThumbY = native.Gamepad.RightThumbY;
            return state;
        }

        public static bool IsNeutral(ControllerState state)
        {
            return state.Connected
                && state.Buttons == 0
                && state.LeftTrigger < 40
                && state.RightTrigger < 40
                && Math.Abs((int)state.LeftThumbX) < 9000
                && Math.Abs((int)state.LeftThumbY) < 9000
                && Math.Abs((int)state.RightThumbX) < 9000
                && Math.Abs((int)state.RightThumbY) < 9000;
        }

        public static string DetectButton(ControllerState state)
        {
            if (!state.Connected) return null;

            ushort[] masks = {
                0x0001, 0x0002, 0x0004, 0x0008,
                0x0010, 0x0020, 0x0040, 0x0080,
                0x0100, 0x0200, 0x1000, 0x2000,
                0x4000, 0x8000
            };
            string[] names = {
                "DpadUp", "DpadDown", "DpadLeft", "DpadRight",
                "Start", "Back", "LeftThumb", "RightThumb",
                "LeftShoulder", "RightShoulder", "A", "B", "X", "Y"
            };
            for (int i = 0; i < masks.Length; i++)
            {
                if ((state.Buttons & masks[i]) != 0) return names[i];
            }

            if (state.LeftTrigger > 100) return "LeftTrigger";
            if (state.RightTrigger > 100) return "RightTrigger";
            if (state.LeftThumbY > 17000) return "LStickUp";
            if (state.LeftThumbY < -17000) return "LStickDown";
            if (state.LeftThumbX < -17000) return "LStickLeft";
            if (state.LeftThumbX > 17000) return "LStickRight";
            if (state.RightThumbY > 17000) return "RStickUp";
            if (state.RightThumbY < -17000) return "RStickDown";
            if (state.RightThumbX < -17000) return "RStickLeft";
            if (state.RightThumbX > 17000) return "RStickRight";
            return null;
        }

        public static string DetectAxis(ControllerState state)
        {
            if (!state.Connected) return null;

            int best = 15000;
            string result = null;
            int value = Math.Abs((int)state.LeftThumbX);
            if (value > best) { best = value; result = "LeftThumbX Axis"; }
            value = Math.Abs((int)state.LeftThumbY);
            if (value > best) { best = value; result = "LeftThumbY Axis"; }
            value = Math.Abs((int)state.RightThumbX);
            if (value > best) { best = value; result = "RightThumbX Axis"; }
            value = Math.Abs((int)state.RightThumbY);
            if (value > best) { result = "RightThumbY Axis"; }
            return result;
        }
    }

    public static class WindowTools
    {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        private static string Title(IntPtr window)
        {
            StringBuilder text = new StringBuilder(1024);
            GetWindowText(window, text, text.Capacity);
            return text.ToString();
        }

        public static bool HideWindow(int processId, string exactTitle)
        {
            bool found = false;
            EnumWindows(delegate(IntPtr window, IntPtr unused)
            {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (owner == (uint)processId && Title(window) == exactTitle)
                {
                    ShowWindow(window, 0);
                    found = true;
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        public static bool HasVisibleWindow(int processId, string titlePart)
        {
            bool found = false;
            EnumWindows(delegate(IntPtr window, IntPtr unused)
            {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (owner == (uint)processId
                    && IsWindowVisible(window)
                    && Title(window).IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    found = true;
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }
    }
}
'@

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRomName = "Zombies Ate My Neighbors (USA).sfc"
$PatchedRomName = "Zombies Ate My Neighbors DX.sfc"
$SourceRom = Join-Path $Root $SourceRomName
$PatchedRom = Join-Path $Root "dist\$PatchedRomName"
$IpsPath = Join-Path $Root "dist\zamndx.ips"
$LuaPath = Join-Path $Root "mod\zamndx.lua"
$LuaConfigPath = Join-Path $Root "mod\zamndx-controller-config.lua"
$AppDataRoot = Join-Path $env:LOCALAPPDATA "ZAMNDX"
$SettingsPath = Join-Path $AppDataRoot "controller.json"
$BizHawkInstall = Join-Path $AppDataRoot "BizHawk"

$ExpectedSourceHash = "B27E2E957FA760F4F483E2AF30E03062034A6C0066984F2E284CC2CB430B2059"
$ExpectedPatchedHash = "4B544A574C3D3D41171CD4F96DBA32B3BC694EACC561ADAB33212A4958DDB85B"

$Colors = @{
    Background = [System.Drawing.ColorTranslator]::FromHtml("#0B0D18")
    Surface = [System.Drawing.ColorTranslator]::FromHtml("#14182A")
    SurfaceRaised = [System.Drawing.ColorTranslator]::FromHtml("#1C2138")
    Purple = [System.Drawing.ColorTranslator]::FromHtml("#8B5CF6")
    PurpleHover = [System.Drawing.ColorTranslator]::FromHtml("#A78BFA")
    Lime = [System.Drawing.ColorTranslator]::FromHtml("#B7F34A")
    LimeHover = [System.Drawing.ColorTranslator]::FromHtml("#CCFF70")
    Text = [System.Drawing.ColorTranslator]::FromHtml("#F5F7FF")
    Muted = [System.Drawing.ColorTranslator]::FromHtml("#9AA3B8")
    Border = [System.Drawing.ColorTranslator]::FromHtml("#303754")
    Danger = [System.Drawing.ColorTranslator]::FromHtml("#FF7188")
}

function New-DefaultSettings {
    return [ordered]@{
        device = "X1"
        deadzone = 0.18
        invert_left_y = $true
        invert_right_y = $true
        enabled = $true
        buttons = [ordered]@{
            Up = "DpadUp"
            Down = "DpadDown"
            Left = "DpadLeft"
            Right = "DpadRight"
            Start = "Start"
            Select = "Back"
            Y = "X"
            B = "A"
            A = "B"
            X = "Y"
            L = "LeftShoulder"
            R = "RightShoulder"
        }
        axes = [ordered]@{
            left_x = "LeftThumbX Axis"
            left_y = "LeftThumbY Axis"
            right_x = "RightThumbX Axis"
            right_y = "RightThumbY Axis"
        }
    }
}

function Copy-Settings($Source) {
    return ($Source | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
}

function Load-ControllerSettings {
    $defaults = New-DefaultSettings
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return Copy-Settings $defaults
    }

    try {
        $loaded = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
        if ($loaded.device -match "^X[1-4]$") {
            $defaults.device = $loaded.device
        }
        if ($null -ne $loaded.deadzone) {
            $defaults.deadzone = [Math]::Max(0.0, [Math]::Min(0.9, [double]$loaded.deadzone))
        }
        if ($null -ne $loaded.invert_left_y) {
            $defaults.invert_left_y = [bool]$loaded.invert_left_y
        }
        if ($null -ne $loaded.invert_right_y) {
            $defaults.invert_right_y = [bool]$loaded.invert_right_y
        }
        foreach ($name in @("Up", "Down", "Left", "Right", "Start", "Select", "Y", "B", "A", "X", "L", "R")) {
            if (-not [string]::IsNullOrWhiteSpace($loaded.buttons.$name)) {
                $defaults.buttons[$name] = [string]$loaded.buttons.$name
            }
        }
        foreach ($name in @("left_x", "left_y", "right_x", "right_y")) {
            if (-not [string]::IsNullOrWhiteSpace($loaded.axes.$name)) {
                $defaults.axes[$name] = [string]$loaded.axes.$name
            }
        }
    } catch {
        # A malformed local profile should never prevent the launcher from opening.
    }
    return Copy-Settings $defaults
}

$script:Settings = Load-ControllerSettings
$script:Capture = $null

function Escape-LuaString([string]$Value) {
    return '"' + $Value.Replace("\", "\\").Replace('"', '\"') + '"'
}

function Save-ControllerSettings {
    [System.IO.Directory]::CreateDirectory($AppDataRoot) | Out-Null
    $script:Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SettingsPath -Encoding UTF8

    $prefix = $script:Settings.device
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("return {")
    $lines.Add("`tdevice = $(Escape-LuaString $prefix),")
    $lines.Add("`tdeadzone = $([double]$script:Settings.deadzone),")
    $lines.Add("`tinvert_left_y = $($script:Settings.invert_left_y.ToString().ToLowerInvariant()),")
    $lines.Add("`tinvert_right_y = $($script:Settings.invert_right_y.ToString().ToLowerInvariant()),")
    $lines.Add("`tenabled = true,")
    $lines.Add("`tshow_overlay = false,")
    $lines.Add("`tbuttons = {")
    foreach ($name in @("Up", "Down", "Left", "Right", "Start", "Select", "Y", "B", "A", "X", "L", "R")) {
        $binding = "$prefix $($script:Settings.buttons.$name)"
        $lines.Add("`t`t$name = $(Escape-LuaString $binding),")
    }
    $lines.Add("`t},")
    $lines.Add("`taxes = {")
    foreach ($name in @("left_x", "left_y", "right_x", "right_y")) {
        $binding = "$prefix $($script:Settings.axes.$name)"
        $lines.Add("`t`t$name = $(Escape-LuaString $binding),")
    }
    $lines.Add("`t},")
    $lines.Add("}")
    $lines | Set-Content -LiteralPath $LuaConfigPath -Encoding UTF8
}

function Show-Error([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        "ZAMN DX",
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
        $offset = (($patch[$position] -shl 16) -bor ($patch[$position + 1] -shl 8) -bor $patch[$position + 2])
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

        while ($rom.Count -lt $offset + $size) {
            $rom.Add(0)
        }
        for ($index = 0; $index -lt $size; $index++) {
            $rom[$offset + $index] = $replacement[$index]
        }
    }

    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath)) | Out-Null
    [System.IO.File]::WriteAllBytes($OutputPath, $rom.ToArray())
}

function Ensure-PatchedRom {
    if ((Test-Path -LiteralPath $PatchedRom) -and (Get-Sha256 $PatchedRom) -eq $ExpectedPatchedHash) {
        return
    }

    $selectedSource = $SourceRom
    if (-not (Test-Path -LiteralPath $selectedSource)) {
        $selectedSource = Select-SourceRom
    }
    $actualHash = Get-Sha256 $selectedSource
    if ($actualHash -ne $ExpectedSourceHash) {
        throw "This is not the supported headerless USA ROM.`n`nExpected SHA-256:`n$ExpectedSourceHash`n`nSelected ROM SHA-256:`n$actualHash"
    }

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
        "BizHawk is needed to play the mod. Download the latest official Windows release now?",
        "ZAMN DX",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        throw "BizHawk is required to play with analog and twin-stick controls."
    }

    $headers = @{ "User-Agent" = "ZAMNDX-Launcher" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/TASEmulators/BizHawk/releases/latest" -Headers $headers
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

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [float]$Size = 10, $Color = $Colors.Text, [string]$Style = "Regular") {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.Font = New-Object System.Drawing.Font("Segoe UI", $Size, [System.Drawing.FontStyle]::$Style)
    return $label
}

function New-ThemedButton([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, $BackColor, $ForeColor, $HoverColor) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = $BackColor
    $button.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Tag = [pscustomobject]@{ Normal = $BackColor; Hover = $HoverColor; Target = $null; Kind = $null }
    $button.Add_MouseEnter({ $this.BackColor = $this.Tag.Hover })
    $button.Add_MouseLeave({ $this.BackColor = $this.Tag.Normal })
    return $button
}

function Get-ControllerSlot {
    return [int]$script:Settings.device.Substring(1, 1) - 1
}

function Get-FriendlyBinding([string]$Binding) {
    $names = @{
        DpadUp = "D-pad Up"; DpadDown = "D-pad Down"; DpadLeft = "D-pad Left"; DpadRight = "D-pad Right"
        LeftShoulder = "Left Bumper"; RightShoulder = "Right Bumper"
        LeftThumb = "Left Stick Click"; RightThumb = "Right Stick Click"
        LeftTrigger = "Left Trigger"; RightTrigger = "Right Trigger"
        LStickUp = "Left Stick Up"; LStickDown = "Left Stick Down"; LStickLeft = "Left Stick Left"; LStickRight = "Left Stick Right"
        RStickUp = "Right Stick Up"; RStickDown = "Right Stick Down"; RStickLeft = "Right Stick Left"; RStickRight = "Right Stick Right"
        "LeftThumbX Axis" = "Left Stick X"; "LeftThumbY Axis" = "Left Stick Y"
        "RightThumbX Axis" = "Right Stick X"; "RightThumbY Axis" = "Right Stick Y"
    }
    if ($names.ContainsKey($Binding)) {
        return $names[$Binding]
    }
    return $Binding
}

function Show-ControllerConfiguration([System.Windows.Forms.Form]$Owner) {
    $original = Copy-Settings $script:Settings
    $working = Copy-Settings $script:Settings
    $script:Settings = $working
    $script:Capture = $null

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Configure Controller"
    $form.ClientSize = New-Object System.Drawing.Size(860, 690)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $form.BackColor = $Colors.Background
    $form.ForeColor = $Colors.Text
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    $form.Controls.Add((New-Label "CONTROLLER SETUP" 28 22 340 35 20 $Colors.Text "Bold"))
    $form.Controls.Add((New-Label "Press Capture, release the controls, then press or move the input you want." 30 58 650 24 10 $Colors.Muted))

    $deviceLabel = New-Label "Controller" 30 101 90 22 10 $Colors.Muted "Bold"
    $form.Controls.Add($deviceLabel)
    $device = New-Object System.Windows.Forms.ComboBox
    $device.Location = New-Object System.Drawing.Point(30, 126)
    $device.Size = New-Object System.Drawing.Size(220, 30)
    $device.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $device.BackColor = $Colors.SurfaceRaised
    $device.ForeColor = $Colors.Text
    [void]$device.Items.AddRange(@("Controller 1 (X1)", "Controller 2 (X2)", "Controller 3 (X3)", "Controller 4 (X4)"))
    $device.SelectedIndex = Get-ControllerSlot
    $form.Controls.Add($device)

    $deadzoneLabel = New-Label "Stick deadzone: $([Math]::Round([double]$working.deadzone * 100))%" 280 101 200 22 10 $Colors.Muted "Bold"
    $form.Controls.Add($deadzoneLabel)
    $deadzone = New-Object System.Windows.Forms.TrackBar
    $deadzone.Location = New-Object System.Drawing.Point(274, 125)
    $deadzone.Size = New-Object System.Drawing.Size(225, 40)
    $deadzone.Minimum = 5
    $deadzone.Maximum = 45
    $deadzone.TickFrequency = 5
    $deadzone.Value = [int]([Math]::Round([double]$working.deadzone * 100))
    $deadzone.BackColor = $Colors.Background
    $form.Controls.Add($deadzone)

    $invertLeft = New-Object System.Windows.Forms.CheckBox
    $invertLeft.Text = "Invert left-stick Y"
    $invertLeft.Location = New-Object System.Drawing.Point(532, 111)
    $invertLeft.Size = New-Object System.Drawing.Size(145, 25)
    $invertLeft.Checked = [bool]$working.invert_left_y
    $invertLeft.ForeColor = $Colors.Text
    $invertLeft.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $form.Controls.Add($invertLeft)

    $invertRight = New-Object System.Windows.Forms.CheckBox
    $invertRight.Text = "Invert right-stick Y"
    $invertRight.Location = New-Object System.Drawing.Point(690, 111)
    $invertRight.Size = New-Object System.Drawing.Size(150, 25)
    $invertRight.Checked = [bool]$working.invert_right_y
    $invertRight.ForeColor = $Colors.Text
    $invertRight.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $form.Controls.Add($invertRight)

    $monitor = New-Object System.Windows.Forms.Panel
    $monitor.Location = New-Object System.Drawing.Point(30, 176)
    $monitor.Size = New-Object System.Drawing.Size(800, 76)
    $monitor.BackColor = $Colors.Surface
    $form.Controls.Add($monitor)
    $connection = New-Label "Checking controller..." 18 12 250 24 11 $Colors.Muted "Bold"
    $activity = New-Label "Move a stick or press a button to test it." 18 41 750 22 10 $Colors.Muted
    $monitor.Controls.Add($connection)
    $monitor.Controls.Add($activity)

    $form.Controls.Add((New-Label "ANALOG STICKS" 30 276 180 22 10 $Colors.Purple "Bold"))
    $form.Controls.Add((New-Label "SNES BUTTONS" 30 378 180 22 10 $Colors.Purple "Bold"))

    $bindingLabels = @{}
    $axisRows = @(
        @("left_x", "Move horizontal"),
        @("left_y", "Move vertical"),
        @("right_x", "Aim horizontal"),
        @("right_y", "Aim vertical")
    )
    for ($index = 0; $index -lt $axisRows.Count; $index++) {
        $x = 30 + ($index % 2) * 400
        $y = 306 + [Math]::Floor($index / 2) * 38
        $name = $axisRows[$index][0]
        $form.Controls.Add((New-Label $axisRows[$index][1] $x ($y + 7) 120 22 9.5 $Colors.Text))
        $value = New-Label (Get-FriendlyBinding $working.axes.$name) ($x + 124) ($y + 7) 150 22 9.5 $Colors.Muted
        $bindingLabels[$name] = $value
        $form.Controls.Add($value)
        $captureButton = New-ThemedButton "Capture" ($x + 286) $y 86 30 $Colors.SurfaceRaised $Colors.Text $Colors.Purple
        $captureButton.Tag.Target = $name
        $captureButton.Tag.Kind = "axis"
        $form.Controls.Add($captureButton)
    }

    $buttonRows = @(
        @("Up", "Move Up"), @("Down", "Move Down"), @("Left", "Move Left"),
        @("Right", "Move Right"), @("Start", "Start"), @("Select", "Select"),
        @("Y", "Fire / Use"), @("B", "Cancel"), @("A", "Item"),
        @("X", "Cycle Item"), @("L", "Previous Weapon"), @("R", "Next Weapon")
    )
    for ($index = 0; $index -lt $buttonRows.Count; $index++) {
        $column = [Math]::Floor($index / 6)
        $row = $index % 6
        $x = 30 + $column * 400
        $y = 407 + $row * 36
        $name = $buttonRows[$index][0]
        $form.Controls.Add((New-Label $buttonRows[$index][1] $x ($y + 7) 120 22 9.5 $Colors.Text))
        $value = New-Label (Get-FriendlyBinding $working.buttons.$name) ($x + 124) ($y + 7) 150 22 9.5 $Colors.Muted
        $bindingLabels[$name] = $value
        $form.Controls.Add($value)
        $captureButton = New-ThemedButton "Capture" ($x + 286) $y 86 30 $Colors.SurfaceRaised $Colors.Text $Colors.Purple
        $captureButton.Tag.Target = $name
        $captureButton.Tag.Kind = "button"
        $form.Controls.Add($captureButton)
    }

    $captureStatus = New-Label "Ready" 30 628 390 26 10 $Colors.Muted "Bold"
    $form.Controls.Add($captureStatus)
    $defaultsButton = New-ThemedButton "Restore Defaults" 445 622 130 38 $Colors.SurfaceRaised $Colors.Text $Colors.Purple
    $cancelButton = New-ThemedButton "Cancel" 588 622 90 38 $Colors.SurfaceRaised $Colors.Text $Colors.Purple
    $saveButton = New-ThemedButton "Save" 691 622 139 38 $Colors.Lime $Colors.Background $Colors.LimeHover
    $form.Controls.AddRange(@($defaultsButton, $cancelButton, $saveButton))

    $device.Add_SelectedIndexChanged({
        $script:Settings.device = "X$($device.SelectedIndex + 1)"
        $script:Capture = $null
        $captureStatus.Text = "Switched to $($script:Settings.device)"
        $captureStatus.ForeColor = $Colors.Muted
    })
    $deadzone.Add_ValueChanged({
        $deadzoneLabel.Text = "Stick deadzone: $($deadzone.Value)%"
        $script:Settings.deadzone = $deadzone.Value / 100.0
    })
    $invertLeft.Add_CheckedChanged({ $script:Settings.invert_left_y = $invertLeft.Checked })
    $invertRight.Add_CheckedChanged({ $script:Settings.invert_right_y = $invertRight.Checked })

    foreach ($control in $form.Controls) {
        if ($control -is [System.Windows.Forms.Button] -and $control.Text -eq "Capture") {
            $control.Add_Click({
                $script:Capture = [pscustomobject]@{
                    Kind = $this.Tag.Kind
                    Target = $this.Tag.Target
                    Armed = $false
                }
                $captureStatus.Text = "Release all controls..."
                $captureStatus.ForeColor = $Colors.Lime
            })
        }
    }

    $defaultsButton.Add_Click({
        $defaults = New-DefaultSettings
        $defaults.device = $script:Settings.device
        $script:Settings = Copy-Settings $defaults
        $deadzone.Value = [int]([Math]::Round([double]$script:Settings.deadzone * 100))
        $invertLeft.Checked = [bool]$script:Settings.invert_left_y
        $invertRight.Checked = [bool]$script:Settings.invert_right_y
        foreach ($row in $axisRows) {
            $bindingLabels[$row[0]].Text = Get-FriendlyBinding $script:Settings.axes.($row[0])
        }
        foreach ($row in $buttonRows) {
            $bindingLabels[$row[0]].Text = Get-FriendlyBinding $script:Settings.buttons.($row[0])
        }
        $captureStatus.Text = "Defaults restored"
        $captureStatus.ForeColor = $Colors.Muted
    })
    $cancelButton.Add_Click({
        $script:Settings = Copy-Settings $original
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $saveButton.Add_Click({
        Save-ControllerSettings
        $captureStatus.Text = "Controller profile saved"
        $captureStatus.ForeColor = $Colors.Lime
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 30
    $timer.Add_Tick({
        $state = [Zamndx.XInput]::Read((Get-ControllerSlot))
        if (-not $state.Connected) {
            $connection.Text = "$($script:Settings.device) not connected"
            $connection.ForeColor = $Colors.Danger
            $activity.Text = "Connect the controller or choose another slot."
            return
        }

        $connection.Text = "$($script:Settings.device) connected"
        $connection.ForeColor = $Colors.Lime
        $pressed = [Zamndx.XInput]::DetectButton($state)
        if ($pressed) {
            $activity.Text = "Input detected: $(Get-FriendlyBinding $pressed)"
            $activity.ForeColor = $Colors.Text
        } else {
            $left = [Math]::Round([Math]::Sqrt([Math]::Pow($state.LeftThumbX / 32767.0, 2) + [Math]::Pow($state.LeftThumbY / 32767.0, 2)) * 100)
            $right = [Math]::Round([Math]::Sqrt([Math]::Pow($state.RightThumbX / 32767.0, 2) + [Math]::Pow($state.RightThumbY / 32767.0, 2)) * 100)
            $activity.Text = "Left stick $left%   |   Right stick $right%   |   Triggers $($state.LeftTrigger)/$($state.RightTrigger)"
            $activity.ForeColor = $Colors.Muted
        }

        if ($null -eq $script:Capture) {
            return
        }
        if (-not $script:Capture.Armed) {
            if ([Zamndx.XInput]::IsNeutral($state)) {
                $script:Capture.Armed = $true
                $captureStatus.Text = if ($script:Capture.Kind -eq "axis") { "Move the desired stick axis..." } else { "Press the desired control..." }
            }
            return
        }

        $binding = if ($script:Capture.Kind -eq "axis") {
            [Zamndx.XInput]::DetectAxis($state)
        } else {
            [Zamndx.XInput]::DetectButton($state)
        }
        if ([string]::IsNullOrWhiteSpace($binding)) {
            return
        }

        $target = $script:Capture.Target
        if ($script:Capture.Kind -eq "axis") {
            $script:Settings.axes.$target = $binding
        } else {
            $script:Settings.buttons.$target = $binding
        }
        $bindingLabels[$target].Text = Get-FriendlyBinding $binding
        $captureStatus.Text = "Assigned $(Get-FriendlyBinding $binding)"
        $captureStatus.ForeColor = $Colors.Lime
        $script:Capture = $null
    })
    $form.Add_Shown({ $timer.Start() })
    $form.Add_FormClosed({
        $timer.Stop()
        $timer.Dispose()
        $script:Capture = $null
        if ($form.DialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
            $script:Settings = Copy-Settings $original
        }
    })
    [void]$form.ShowDialog($Owner)
}

function Start-Game([System.Windows.Forms.Form]$Launcher, [System.Windows.Forms.Label]$Status, [System.Windows.Forms.Button[]]$Buttons) {
    foreach ($button in $Buttons) {
        $button.Enabled = $false
    }
    try {
        $Status.Text = "Preparing game files..."
        $Status.ForeColor = $Colors.Lime
        [System.Windows.Forms.Application]::DoEvents()
        Ensure-PatchedRom
        Save-ControllerSettings

        $Status.Text = "Finding BizHawk..."
        [System.Windows.Forms.Application]::DoEvents()
        $emulator = Find-BizHawk
        if (-not $emulator) {
            $emulator = Install-BizHawk
        }

        $Status.Text = "Starting in full screen..."
        [System.Windows.Forms.Application]::DoEvents()
        $arguments = @(
            "--gdi",
            "--fullscreen",
            "--chromeless",
            "--lua",
            "`"$LuaPath`"",
            "`"$PatchedRom`""
        )
        $process = Start-Process `
            -FilePath $emulator `
            -WorkingDirectory (Split-Path -Parent $emulator) `
            -ArgumentList $arguments `
            -PassThru

        for ($attempt = 0; $attempt -lt 150; $attempt++) {
            Start-Sleep -Milliseconds 100
            [System.Windows.Forms.Application]::DoEvents()
            [void][Zamndx.WindowTools]::HideWindow($process.Id, "Lua Console")
            if ($process.HasExited) {
                throw "BizHawk closed before the game finished starting."
            }
            if ([Zamndx.WindowTools]::HasVisibleWindow($process.Id, "Zombies Ate My Neighbors DX")) {
                break
            }
        }
        [void][Zamndx.WindowTools]::HideWindow($process.Id, "Lua Console")

        $monitor = New-Object System.Windows.Forms.Timer
        $monitor.Interval = 250
        $monitorHandler = {
            if ($process.HasExited) {
                $monitor.Stop()
                $monitor.Dispose()
                foreach ($button in $Buttons) {
                    $button.Enabled = $true
                }
                $Status.Text = "Game closed - ready to play"
                $Status.ForeColor = $Colors.Muted
                $Launcher.Show()
                $Launcher.Activate()
                return
            }
            [void][Zamndx.WindowTools]::HideWindow($process.Id, "Lua Console")
        }.GetNewClosure()
        $monitor.Add_Tick($monitorHandler)
        $Launcher.Hide()
        $monitor.Start()
    } catch {
        $Status.Text = "Could not start the game"
        $Status.ForeColor = $Colors.Danger
        Show-Error $_.Exception.Message
        foreach ($button in $Buttons) {
            $button.Enabled = $true
        }
    }
}

function Show-Launcher {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Zombies Ate My Neighbors DX"
    $form.ClientSize = New-Object System.Drawing.Size(720, 520)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = $Colors.Background
    $form.ForeColor = $Colors.Text
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Location = New-Object System.Drawing.Point(0, 0)
    $accent.Size = New-Object System.Drawing.Size(8, 520)
    $accent.BackColor = $Colors.Purple
    $form.Controls.Add($accent)

    $form.Controls.Add((New-Label "ZOMBIES ATE MY NEIGHBORS" 48 38 500 24 11 $Colors.Muted "Bold"))
    $form.Controls.Add((New-Label "DX" 46 63 150 74 42 $Colors.Lime "Bold"))
    $form.Controls.Add((New-Label "Analog movement. Twin-stick shooting. Bigger hitboxes." 50 139 560 30 12 $Colors.Text))

    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point(48, 193)
    $card.Size = New-Object System.Drawing.Size(624, 106)
    $card.BackColor = $Colors.Surface
    $form.Controls.Add($card)
    $badge = New-Label "MOD READY" 22 18 104 24 9 $Colors.Lime "Bold"
    $card.Controls.Add($badge)
    $card.Controls.Add((New-Label "50% larger interactions" 22 50 185 24 10 $Colors.Text "Bold"))
    $card.Controls.Add((New-Label "360-degree movement" 218 50 185 24 10 $Colors.Text "Bold"))
    $card.Controls.Add((New-Label "Independent aiming" 414 50 175 24 10 $Colors.Text "Bold"))
    $card.Controls.Add((New-Label "Enemy and item contact" 22 75 185 20 9 $Colors.Muted))
    $card.Controls.Add((New-Label "Variable speed on left stick" 218 75 190 20 9 $Colors.Muted))
    $card.Controls.Add((New-Label "Fire with the right stick" 414 75 185 20 9 $Colors.Muted))

    $playButton = New-ThemedButton "Play Game" 48 330 296 58 $Colors.Lime $Colors.Background $Colors.LimeHover
    $configureButton = New-ThemedButton "Configure Controller" 376 330 296 58 $Colors.Purple $Colors.Text $Colors.PurpleHover
    $quitButton = New-ThemedButton "Quit" 48 405 624 42 $Colors.SurfaceRaised $Colors.Text $Colors.Purple
    $form.Controls.AddRange(@($playButton, $configureButton, $quitButton))

    $status = New-Label "Checking controller..." 49 473 620 22 9.5 $Colors.Muted
    $form.Controls.Add($status)

    $playButton.Add_Click({ Start-Game $form $status @($playButton, $configureButton, $quitButton) })
    $configureButton.Add_Click({
        Show-ControllerConfiguration $form
        $mainState = [Zamndx.XInput]::Read((Get-ControllerSlot))
        $status.Text = if ($mainState.Connected) { "$($script:Settings.device) connected and ready" } else { "$($script:Settings.device) is not connected" }
        $status.ForeColor = if ($mainState.Connected) { $Colors.Lime } else { $Colors.Muted }
    })
    $quitButton.Add_Click({ $form.Close() })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 750
    $timer.Add_Tick({
        $state = [Zamndx.XInput]::Read((Get-ControllerSlot))
        $status.Text = if ($state.Connected) { "$($script:Settings.device) connected and ready" } else { "$($script:Settings.device) is not connected - configure or reconnect it" }
        $status.ForeColor = if ($state.Connected) { $Colors.Lime } else { $Colors.Muted }
    })
    $form.Add_Shown({ $timer.Start() })
    $form.Add_FormClosed({
        $timer.Stop()
        $timer.Dispose()
    })
    [System.Windows.Forms.Application]::Run($form)
}

try {
    if (-not (Test-Path -LiteralPath $IpsPath)) {
        throw "Missing patch: $IpsPath"
    }
    if (-not (Test-Path -LiteralPath $LuaPath)) {
        throw "Missing controller script: $LuaPath"
    }

    if ($NoLaunch) {
        Ensure-PatchedRom
        Save-ControllerSettings
        $emulator = Find-BizHawk
        if (-not $emulator) {
            $emulator = Install-BizHawk
        }
        Write-Host "Launcher check passed."
        Write-Host "ROM: $PatchedRom"
        Write-Host "BizHawk: $emulator"
        Write-Host "Controller: $($script:Settings.device)"
        exit 0
    }

    Show-Launcher
} catch {
    Show-Error $_.Exception.Message
    exit 1
}
