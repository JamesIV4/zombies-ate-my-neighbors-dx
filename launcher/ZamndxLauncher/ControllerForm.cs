namespace ZamndxLauncher;

internal sealed class ControllerForm : Form
{
    private static readonly Dictionary<string, string> FriendlyNames = new()
    {
        ["A"] = "A (south)",
        ["B"] = "B (east)",
        ["X"] = "X (west)",
        ["Y"] = "Y (north)",
        ["Start"] = "Start",
        ["Back"] = "Back",
        ["DpadUp"] = "D-pad Up",
        ["DpadDown"] = "D-pad Down",
        ["DpadLeft"] = "D-pad Left",
        ["DpadRight"] = "D-pad Right",
        ["LeftShoulder"] = "Left Bumper",
        ["RightShoulder"] = "Right Bumper",
        ["LeftThumb"] = "Left Stick Click",
        ["RightThumb"] = "Right Stick Click",
        ["LeftTrigger"] = "Left Trigger",
        ["RightTrigger"] = "Right Trigger",
        ["LStickUp"] = "Left Stick Up",
        ["LStickDown"] = "Left Stick Down",
        ["LStickLeft"] = "Left Stick Left",
        ["LStickRight"] = "Left Stick Right",
        ["RStickUp"] = "Right Stick Up",
        ["RStickDown"] = "Right Stick Down",
        ["RStickLeft"] = "Right Stick Left",
        ["RStickRight"] = "Right Stick Right",
        ["LeftThumbX Axis"] = "Left Stick X",
        ["LeftThumbY Axis"] = "Left Stick Y",
        ["RightThumbX Axis"] = "Right Stick X",
        ["RightThumbY Axis"] = "Right Stick Y",
    };

    private readonly ControllerSettings _settings;
    private readonly ControlScheme _scheme;
    private readonly Dictionary<string, Label> _bindingLabels = [];
    private readonly Label _connection;
    private readonly Label _activity;
    private readonly Label _captureStatus;
    private readonly ComboBox _device;
    private readonly TrackBar _deadzone;
    private readonly Label _deadzoneLabel;
    private readonly CheckBox _invertLeft;
    private readonly CheckBox _invertRight;
    private readonly System.Windows.Forms.Timer _timer;
    private CaptureRequest? _capture;

    internal ControllerSettings? SavedSettings { get; private set; }

    internal ControllerForm(ControllerSettings current, ControlScheme scheme)
    {
        _settings = current.Clone();
        _scheme = scheme;

        Text = "Configure Controller";
        ClientSize = new Size(860, 736);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        Font = new Font("Segoe UI", 10);
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

        Controls.Add(Theme.Label("CONTROLLER SETUP", 28, 22, 340, 35, 20, Theme.Text, FontStyle.Bold));
        Controls.Add(Theme.Label(
            "Press Capture, release the controls, then press or move the input you want.",
            30, 58, 650, 24, 10, Theme.Muted));

        Controls.Add(Theme.Label("Controller", 30, 101, 90, 22, 10, Theme.Muted, FontStyle.Bold));
        _device = new ComboBox
        {
            Location = new Point(30, 126),
            Size = new Size(220, 30),
            DropDownStyle = ComboBoxStyle.DropDownList,
            BackColor = Theme.SurfaceRaised,
            ForeColor = Theme.Text,
        };
        _device.Items.AddRange(
        [
            "Controller 1 (X1)",
            "Controller 2 (X2)",
            "Controller 3 (X3)",
            "Controller 4 (X4)",
        ]);
        _device.SelectedIndex = DeviceSlot;
        _device.SelectedIndexChanged += (_, _) =>
        {
            _settings.Device = $"X{_device.SelectedIndex + 1}";
            _capture = null;
            SetCaptureStatus($"Switched to {_settings.Device}", Theme.Muted);
        };
        Controls.Add(_device);

        _deadzoneLabel = Theme.Label(
            $"Stick deadzone: {Math.Round(_settings.Deadzone * 100)}%",
            280, 101, 200, 22, 10, Theme.Muted, FontStyle.Bold);
        Controls.Add(_deadzoneLabel);
        _deadzone = new TrackBar
        {
            Location = new Point(274, 125),
            Size = new Size(225, 40),
            Minimum = 5,
            Maximum = 45,
            TickFrequency = 5,
            Value = (int)Math.Round(_settings.Deadzone * 100),
            BackColor = Theme.Background,
        };
        _deadzone.ValueChanged += (_, _) =>
        {
            _settings.Deadzone = _deadzone.Value / 100.0;
            _deadzoneLabel.Text = $"Stick deadzone: {_deadzone.Value}%";
        };
        Controls.Add(_deadzone);

        // The saved setting follows the user-facing checkbox. The runtime/Lua flag is
        // opposite, so ModRuntime flips it when writing zamndx-controller-config.lua.
        _invertLeft = CheckBox("Invert left-stick Y", 532, 111, _settings.InvertLeftY);
        _invertRight = CheckBox("Invert right-stick Y", 690, 111, _settings.InvertRightY);
        _invertLeft.CheckedChanged += (_, _) => _settings.InvertLeftY = _invertLeft.Checked;
        _invertRight.CheckedChanged += (_, _) => _settings.InvertRightY = _invertRight.Checked;
        Controls.Add(_invertLeft);
        Controls.Add(_invertRight);

        var monitor = new Panel
        {
            Location = new Point(30, 176),
            Size = new Size(800, 76),
            BackColor = Theme.Surface,
        };
        _connection = Theme.Label("Checking controller...", 18, 12, 250, 24, 11, Theme.Muted, FontStyle.Bold);
        _activity = Theme.Label("Move a stick or press a button to test it.", 18, 41, 750, 22, 10, Theme.Muted);
        monitor.Controls.Add(_connection);
        monitor.Controls.Add(_activity);
        Controls.Add(monitor);

        Controls.Add(Theme.Label("ANALOG STICKS", 30, 268, 180, 22, 10, Theme.Purple, FontStyle.Bold));

        (string Name, string Label)[] axes =
        [
            ("left_x", "Move horizontal"),
            ("left_y", "Move vertical"),
            ("right_x", "Aim horizontal"),
            ("right_y", "Aim vertical"),
        ];
        for (var index = 0; index < axes.Length; index++)
        {
            var x = 30 + index % 2 * 400;
            var y = 294 + index / 2 * 36;
            AddBindingRow("axis", axes[index].Name, axes[index].Label, x, y, _settings.Axes[axes[index].Name]);
        }

        Controls.Add(Theme.Label(
            $"BUTTONS  -  layout: {_scheme.Name}", 30, 372, 520, 22, 10, Theme.Purple, FontStyle.Bold));
        Controls.Add(Theme.Label(
            "This layout follows your ROM Patches selection.",
            30, 398, 520, 20, 9, Theme.Muted));

        var actions = _scheme.Actions;
        var perColumn = (actions.Count + 1) / 2;
        for (var index = 0; index < actions.Count; index++)
        {
            var action = actions[index];
            var column = index / perColumn;
            var row = index % perColumn;
            AddBindingRow(
                "button",
                action.Id,
                action.Label,
                30 + column * 400,
                426 + row * 34,
                _settings.Bindings[action.Id]);
        }

        _captureStatus = Theme.Label("Ready", 30, 692, 390, 26, 10, Theme.Muted, FontStyle.Bold);
        Controls.Add(_captureStatus);

        var defaults = Theme.Button(
            "Restore Defaults", 445, 686, 130, 38,
            Theme.SurfaceRaised, Theme.Text, Theme.Purple);
        defaults.Click += (_, _) => RestoreDefaults();
        Controls.Add(defaults);

        var cancel = Theme.Button(
            "Cancel", 588, 686, 90, 38,
            Theme.SurfaceRaised, Theme.Text, Theme.Purple);
        cancel.Click += (_, _) =>
        {
            DialogResult = DialogResult.Cancel;
            Close();
        };
        Controls.Add(cancel);

        var save = Theme.Button(
            "Save", 691, 686, 139, 38,
            Theme.Lime, Theme.Background, Theme.LimeHover);
        save.Click += (_, _) =>
        {
            SavedSettings = _settings.Clone();
            SettingsStore.Save(SavedSettings);
            DialogResult = DialogResult.OK;
            Close();
        };
        Controls.Add(save);

        _timer = new System.Windows.Forms.Timer { Interval = 30 };
        _timer.Tick += (_, _) => PollController();
        Shown += (_, _) => _timer.Start();
        FormClosed += (_, _) => _timer.Dispose();
    }

    private int DeviceSlot => int.Parse(_settings.Device[1..]) - 1;

    private static CheckBox CheckBox(string text, int x, int y, bool isChecked)
    {
        return new CheckBox
        {
            Text = text,
            Location = new Point(x, y),
            Size = new Size(155, 25),
            Checked = isChecked,
            ForeColor = Theme.Text,
            FlatStyle = FlatStyle.Flat,
        };
    }

    private void AddBindingRow(
        string kind,
        string target,
        string label,
        int x,
        int y,
        string binding)
    {
        Controls.Add(Theme.Label(label, x, y + 6, 124, 22, 9.5f, Theme.Text));
        var value = Theme.Label(Friendly(binding), x + 128, y + 6, 150, 22, 9.5f, Theme.Muted);
        _bindingLabels[target] = value;
        Controls.Add(value);

        var capture = Theme.Button(
            "Capture", x + 286, y, 86, 28,
            Theme.SurfaceRaised, Theme.Text, Theme.Purple);
        capture.Click += (_, _) =>
        {
            _capture = new CaptureRequest(kind, target, false);
            SetCaptureStatus("Release all controls...", Theme.Lime);
        };
        Controls.Add(capture);
    }

    private void PollController()
    {
        var state = XInput.Read(DeviceSlot);
        if (!state.Connected)
        {
            _connection.Text = $"{_settings.Device} not connected";
            _connection.ForeColor = Theme.Danger;
            _activity.Text = "Connect the controller or choose another slot.";
            return;
        }

        _connection.Text = $"{_settings.Device} connected";
        _connection.ForeColor = Theme.Lime;
        var pressed = XInput.DetectButton(state);
        if (pressed is not null)
        {
            _activity.Text = $"Input detected: {Friendly(pressed)}";
            _activity.ForeColor = Theme.Text;
        }
        else
        {
            var left = StickMagnitude(state.LeftThumbX, state.LeftThumbY);
            var right = StickMagnitude(state.RightThumbX, state.RightThumbY);
            _activity.Text =
                $"Left stick {left}%   |   Right stick {right}%   |   Triggers {state.LeftTrigger}/{state.RightTrigger}";
            _activity.ForeColor = Theme.Muted;
        }

        if (_capture is null)
        {
            return;
        }

        if (!_capture.Armed)
        {
            if (XInput.IsNeutral(state))
            {
                _capture = _capture with { Armed = true };
                SetCaptureStatus(
                    _capture.Kind == "axis"
                        ? "Move the desired stick axis..."
                        : "Press the desired control...",
                    Theme.Lime);
            }
            return;
        }

        var binding = _capture.Kind == "axis"
            ? XInput.DetectAxis(state)
            : XInput.DetectButton(state);
        if (binding is null)
        {
            return;
        }

        if (_capture.Kind == "axis")
        {
            _settings.Axes[_capture.Target] = binding;
        }
        else
        {
            _settings.Bindings[_capture.Target] = binding;
        }

        _bindingLabels[_capture.Target].Text = Friendly(binding);
        SetCaptureStatus($"Assigned {Friendly(binding)}", Theme.Lime);
        _capture = null;
    }

    private void RestoreDefaults()
    {
        var defaults = ControllerSettings.CreateDefault();
        defaults.Device = _settings.Device;
        _settings.Deadzone = defaults.Deadzone;
        _settings.InvertLeftY = defaults.InvertLeftY;
        _settings.InvertRightY = defaults.InvertRightY;
        _settings.Bindings = new Dictionary<string, string>(defaults.Bindings);
        _settings.Axes = new Dictionary<string, string>(defaults.Axes);
        _deadzone.Value = (int)Math.Round(_settings.Deadzone * 100);
        _invertLeft.Checked = _settings.InvertLeftY;
        _invertRight.Checked = _settings.InvertRightY;

        foreach (var action in _scheme.Actions)
        {
            _bindingLabels[action.Id].Text = Friendly(_settings.Bindings[action.Id]);
        }
        foreach (var name in ControllerSettings.AxisOrder)
        {
            _bindingLabels[name].Text = Friendly(_settings.Axes[name]);
        }
        SetCaptureStatus("Defaults restored", Theme.Muted);
    }

    private void SetCaptureStatus(string text, Color color)
    {
        _captureStatus.Text = text;
        _captureStatus.ForeColor = color;
    }

    private static int StickMagnitude(short x, short y)
    {
        var magnitude = Math.Sqrt(Math.Pow(x / 32767.0, 2) + Math.Pow(y / 32767.0, 2));
        return (int)Math.Round(Math.Min(1, magnitude) * 100);
    }

    private static string Friendly(string binding)
    {
        return FriendlyNames.GetValueOrDefault(binding, binding);
    }

    private sealed record CaptureRequest(string Kind, string Target, bool Armed);
}
