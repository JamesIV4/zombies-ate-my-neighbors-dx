using System.Diagnostics;

namespace ZamndxLauncher;

internal sealed class MainForm : Form
{
    private ControllerSettings _settings;
    private readonly Label _status;
    private readonly Button _play;
    private readonly Button _configure;
    private readonly Button _quit;
    private readonly System.Windows.Forms.Timer _controllerTimer;

    private Control CreateSplitTitle()
    {
        var title = new Control
        {
            Location = new Point(46, 38),
            Size = new Size(630, 58),
            BackColor = Theme.Background,
        };

        title.Paint += (_, e) =>
        {
            e.Graphics.TextRenderingHint =
                System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

            using var font = new Font("Segoe UI", 28, FontStyle.Bold);
            using var blueBrush = new SolidBrush(Theme.Blue);
            using var greenBrush = new SolidBrush(Theme.Lime);

            using var format = (StringFormat)StringFormat.GenericTypographic.Clone();
            format.FormatFlags |= StringFormatFlags.NoClip;
            format.Trimming = StringTrimming.None;

            const string main = "Zombies Ate My Neighbors";
            const string dx = "DX";

            var mainSize = e.Graphics.MeasureString(main, font, int.MaxValue, format);

            e.Graphics.DrawString(main, font, blueBrush, 0, 0, format);
            e.Graphics.DrawString(dx, font, greenBrush, mainSize.Width, 0, format);
        };

        return title;
    }

    internal MainForm()
    {
        _settings = SettingsStore.Load();

        Text = "Zombies Ate My Neighbors DX";
        ClientSize = new Size(720, 490);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        Font = new Font("Segoe UI", 10);
        Icon = Theme.CreateIcon();

        Controls.Add(new Panel
        {
            Location = new Point(0, 0),
            Size = new Size(8, 490),
            BackColor = Theme.Purple,
        });
        Controls.Add(CreateSplitTitle());
        Controls.Add(Theme.Label(
            "Analog movement. Twin-stick shooting. Bigger hitboxes.",
            50, 110, 560, 30, 12, Theme.Text));

        var card = new Panel
        {
            Location = new Point(48, 164),
            Size = new Size(624, 106),
            BackColor = Theme.Surface,
        };
        card.Controls.Add(Theme.Label("MOD READY", 22, 18, 104, 24, 9, Theme.Lime, FontStyle.Bold));
        card.Controls.Add(Theme.Label("50% larger interactions", 22, 50, 185, 24, 10, Theme.Text, FontStyle.Bold));
        card.Controls.Add(Theme.Label("360-degree movement", 218, 50, 185, 24, 10, Theme.Text, FontStyle.Bold));
        card.Controls.Add(Theme.Label("Independent aiming", 414, 50, 175, 24, 10, Theme.Text, FontStyle.Bold));
        card.Controls.Add(Theme.Label("Enemy and item contact", 22, 75, 185, 20, 9, Theme.Muted));
        card.Controls.Add(Theme.Label("Variable speed on left stick", 218, 75, 190, 20, 9, Theme.Muted));
        card.Controls.Add(Theme.Label("Fire with the right stick", 414, 75, 185, 20, 9, Theme.Muted));
        Controls.Add(card);

        _play = Theme.Button(
            "Play Game", 48, 301, 296, 58,
            Theme.Lime, Theme.Background, Theme.LimeHover);
        _play.Click += async (_, _) => await PlayGameAsync();
        Controls.Add(_play);

        _configure = Theme.Button(
            "Configure Controller", 376, 301, 296, 58,
            Theme.Purple, Theme.Text, Theme.PurpleHover);
        _configure.Click += (_, _) => ConfigureController();
        Controls.Add(_configure);

        _quit = Theme.Button(
            "Quit", 48, 376, 624, 42,
            Theme.SurfaceRaised, Theme.Text, Theme.Purple);
        _quit.Click += (_, _) => Close();
        Controls.Add(_quit);

        _status = Theme.Label("Checking controller...", 49, 444, 620, 22, 9.5f, Theme.Muted);
        Controls.Add(_status);

        _controllerTimer = new System.Windows.Forms.Timer { Interval = 750 };
        _controllerTimer.Tick += (_, _) => RefreshControllerStatus();
        Shown += (_, _) =>
        {
            RefreshControllerStatus();
            _controllerTimer.Start();
        };
        FormClosed += (_, _) => _controllerTimer.Dispose();
    }

    private int DeviceSlot => int.Parse(_settings.Device[1..]) - 1;

    private void ConfigureController()
    {
        using var form = new ControllerForm(_settings);
        if (form.ShowDialog(this) == DialogResult.OK && form.SavedSettings is not null)
        {
            _settings = form.SavedSettings;
        }
        RefreshControllerStatus();
    }

    private async Task PlayGameAsync()
    {
        SetButtonsEnabled(false);
        try
        {
            SetStatus("Preparing game files...", Theme.Lime);
            await Task.Yield();
            ModRuntime.Prepare(_settings, this);

            SetStatus("Starting in full screen...", Theme.Lime);
            var process = ModRuntime.StartGame();
            Hide();

            while (!process.HasExited)
            {
                WindowTools.HideWindow(process.Id, "Lua Console");
                await Task.Delay(200);
            }

            SetStatus("Game closed - ready to play", Theme.Muted);
            Show();
            Activate();
        }
        catch (Exception exception)
        {
            Show();
            SetStatus("Could not start the game", Theme.Danger);
            MessageBox.Show(
                this,
                exception.Message,
                "ZAMN DX",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        finally
        {
            SetButtonsEnabled(true);
        }
    }

    private void RefreshControllerStatus()
    {
        var state = XInput.Read(DeviceSlot);
        if (state.Connected)
        {
            SetStatus($"{_settings.Device} connected and ready", Theme.Lime);
        }
        else
        {
            SetStatus(
                $"{_settings.Device} is not connected - configure or reconnect it",
                Theme.Muted);
        }
    }

    private void SetButtonsEnabled(bool enabled)
    {
        _play.Enabled = enabled;
        _configure.Enabled = enabled;
        _quit.Enabled = enabled;
    }

    private void SetStatus(string text, Color color)
    {
        _status.Text = text;
        _status.ForeColor = color;
    }
}
