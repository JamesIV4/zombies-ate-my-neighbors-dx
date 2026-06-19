namespace ZamndxLauncher;

internal sealed class PatchesForm : Form
{
    private readonly PatchSettings _settings;
    private readonly Dictionary<string, CheckBox> _toggles = [];

    internal PatchSettings? SavedSettings { get; private set; }

    internal PatchesForm(PatchSettings current)
    {
        _settings = current.Clone();
        var buttonY = Math.Max(416, 182 + RomPatchCatalog.Optional.Count * 78 + 12);

        Text = "Configure ROM Patches";
        ClientSize = new Size(620, buttonY + 54);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        Font = new Font("Segoe UI", 10);
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

        Controls.Add(Theme.Label("ROM PATCHES", 28, 22, 360, 35, 20, Theme.Text, FontStyle.Bold));
        Controls.Add(Theme.Label(
            "Turn optional improvements on or off. Changes are applied the next "
                + "time you start the game.",
            30, 60, 560, 40, 10, Theme.Muted));

        // The core DX mod is always on; show it so players know it is included.
        var core = new Panel
        {
            Location = new Point(30, 108),
            Size = new Size(560, 58),
            BackColor = Theme.Surface,
        };
        core.Controls.Add(Theme.Label(RomPatchCatalog.Base.Name, 16, 9, 380, 22, 11, Theme.Lime, FontStyle.Bold));
        core.Controls.Add(Theme.Label("Always on", 440, 9, 110, 22, 10, Theme.Muted, FontStyle.Bold));
        core.Controls.Add(Theme.Label(RomPatchCatalog.Base.Description, 16, 32, 530, 20, 9, Theme.Muted));
        Controls.Add(core);

        var y = 182;
        foreach (var patch in RomPatchCatalog.Optional)
        {
            y = AddOptionalRow(patch, y);
        }

        if (RomPatchCatalog.Optional.Count == 0)
        {
            Controls.Add(Theme.Label(
                "No optional patches are available in this build.",
                30, y, 560, 24, 10, Theme.Muted));
        }

        var cancel = Theme.Button(
            "Cancel", 378, buttonY, 100, 40,
            Theme.SurfaceRaised, Theme.Text, Theme.Purple);
        cancel.Click += (_, _) =>
        {
            DialogResult = DialogResult.Cancel;
            Close();
        };
        Controls.Add(cancel);

        var save = Theme.Button(
            "Save", 490, buttonY, 100, 40,
            Theme.Lime, Theme.Background, Theme.LimeHover);
        save.Click += (_, _) =>
        {
            _settings.Enabled =
            [
                .. RomPatchCatalog.Optional
                    .Where(patch => _toggles.TryGetValue(patch.Id, out var box) && box.Checked)
                    .Select(patch => patch.Id),
            ];
            SavedSettings = _settings.Clone();
            PatchSettingsStore.Save(SavedSettings);
            DialogResult = DialogResult.OK;
            Close();
        };
        Controls.Add(save);
    }

    private int AddOptionalRow(RomPatch patch, int y)
    {
        var available = RomPatchCatalog.IsAvailable(patch);

        var toggle = new CheckBox
        {
            Text = patch.Name,
            Location = new Point(30, y),
            Size = new Size(540, 26),
            Checked = available && _settings.IsEnabled(patch.Id),
            Enabled = available,
            ForeColor = available ? Theme.Text : Theme.Muted,
            BackColor = Theme.Background,
            FlatStyle = FlatStyle.Flat,
            TextAlign = ContentAlignment.MiddleLeft,
            Font = new Font("Segoe UI Semibold", 11),
        };
        // A transparent background makes the flat check indicator invisible, so
        // the box is given explicit fill/border colours: a clear lime fill when
        // checked and a visible muted border around the dark box when not.
        toggle.FlatAppearance.CheckedBackColor = Theme.Lime;
        toggle.FlatAppearance.BorderColor = Theme.Muted;
        toggle.FlatAppearance.BorderSize = 1;
        _toggles[patch.Id] = toggle;
        Controls.Add(toggle);

        var description = patch.Description;
        if (!available)
        {
            description += "  (not installed)";
        }
        Controls.Add(Theme.Label(description, 52, y + 26, 538, 40, 9.5f, Theme.Muted));

        return y + 78;
    }
}
