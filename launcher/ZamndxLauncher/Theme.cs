namespace ZamndxLauncher;

internal static class Theme
{
    internal static readonly Color Background = ColorTranslator.FromHtml("#0B0D18");
    internal static readonly Color Surface = ColorTranslator.FromHtml("#14182A");
    internal static readonly Color SurfaceRaised = ColorTranslator.FromHtml("#1C2138");
    internal static readonly Color Purple = ColorTranslator.FromHtml("#8B5CF6");
    internal static readonly Color PurpleHover = ColorTranslator.FromHtml("#A78BFA");
    internal static readonly Color Lime = ColorTranslator.FromHtml("#B7F34A");
    internal static readonly Color LimeHover = ColorTranslator.FromHtml("#CCFF70");
    internal static readonly Color Blue = ColorTranslator.FromHtml("#2151ac");
    internal static readonly Color Text = ColorTranslator.FromHtml("#F5F7FF");
    internal static readonly Color Muted = ColorTranslator.FromHtml("#9AA3B8");
    internal static readonly Color Danger = ColorTranslator.FromHtml("#FF7188");

    internal static Label Label(
        string text,
        int x,
        int y,
        int width,
        int height,
        float size = 10,
        Color? color = null,
        FontStyle style = FontStyle.Regular)
    {
        return new Label
        {
            Text = text,
            Location = new Point(x, y),
            Size = new Size(width, height),
            ForeColor = color ?? Text,
            BackColor = Color.Transparent,
            Font = new Font("Segoe UI", size, style),
        };
    }

    internal static Button Button(
        string text,
        int x,
        int y,
        int width,
        int height,
        Color normal,
        Color foreground,
        Color hover)
    {
        var button = new Button
        {
            Text = text,
            Location = new Point(x, y),
            Size = new Size(width, height),
            BackColor = normal,
            ForeColor = foreground,
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI Semibold", 11),
            Cursor = Cursors.Hand,
            UseVisualStyleBackColor = false,
        };
        button.FlatAppearance.BorderSize = 1;
        button.FlatAppearance.BorderColor = normal;
        button.MouseEnter += (_, _) => button.BackColor = hover;
        button.MouseLeave += (_, _) => button.BackColor = normal;
        return button;
    }
}
