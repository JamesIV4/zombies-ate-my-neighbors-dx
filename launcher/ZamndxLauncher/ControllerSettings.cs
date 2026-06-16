using System.Text.Json;

namespace ZamndxLauncher;

internal sealed class ControllerSettings
{
    public string Device { get; set; } = "X1";
    public double Deadzone { get; set; } = 0.18;
    public bool InvertLeftY { get; set; } = false;
    public bool InvertRightY { get; set; } = false;

    /// <summary>
    /// Host control assigned to each control-scheme action id (for example
    /// "fire" or "weapon_prev"). Stored without the device prefix; the runtime
    /// writer prepends the active device.
    /// </summary>
    public Dictionary<string, string> Bindings { get; set; } = DefaultBindings();
    public Dictionary<string, string> Axes { get; set; } = DefaultAxes();

    internal static readonly string[] AxisOrder =
    [
        "left_x", "left_y", "right_x", "right_y",
    ];

    internal static ControllerSettings CreateDefault() => new();

    internal ControllerSettings Clone()
    {
        return new ControllerSettings
        {
            Device = Device,
            Deadzone = Deadzone,
            InvertLeftY = InvertLeftY,
            InvertRightY = InvertRightY,
            Bindings = new Dictionary<string, string>(Bindings),
            Axes = new Dictionary<string, string>(Axes),
        };
    }

    internal static Dictionary<string, string> DefaultBindings()
    {
        var bindings = new Dictionary<string, string>();
        foreach (var action in ControlSchemes.AllActions)
        {
            bindings[action.Id] = action.DefaultHost;
        }
        return bindings;
    }

    private static Dictionary<string, string> DefaultAxes() => new()
    {
        ["left_x"] = "LeftThumbX Axis",
        ["left_y"] = "LeftThumbY Axis",
        ["right_x"] = "RightThumbX Axis",
        ["right_y"] = "RightThumbY Axis",
    };
}

internal static class SettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    internal static ControllerSettings Load()
    {
        if (!File.Exists(AppPaths.SettingsPath))
        {
            return ControllerSettings.CreateDefault();
        }

        try
        {
            var settings = JsonSerializer.Deserialize<ControllerSettings>(
                File.ReadAllText(AppPaths.SettingsPath),
                JsonOptions);
            return Normalize(settings ?? ControllerSettings.CreateDefault());
        }
        catch
        {
            return ControllerSettings.CreateDefault();
        }
    }

    internal static void Save(ControllerSettings settings)
    {
        Directory.CreateDirectory(AppPaths.UserRoot);
        File.WriteAllText(
            AppPaths.SettingsPath,
            JsonSerializer.Serialize(Normalize(settings), JsonOptions));
    }

    private static ControllerSettings Normalize(ControllerSettings settings)
    {
        var defaults = ControllerSettings.CreateDefault();
        if (!System.Text.RegularExpressions.Regex.IsMatch(settings.Device ?? "", "^X[1-4]$"))
        {
            settings.Device = defaults.Device;
        }

        settings.Deadzone = Math.Clamp(settings.Deadzone, 0.05, 0.90);
        settings.Bindings ??= [];
        settings.Axes ??= [];

        foreach (var action in ControlSchemes.AllActions)
        {
            if (!settings.Bindings.TryGetValue(action.Id, out var value) || string.IsNullOrWhiteSpace(value))
            {
                settings.Bindings[action.Id] = defaults.Bindings[action.Id];
            }
        }

        foreach (var name in ControllerSettings.AxisOrder)
        {
            if (!settings.Axes.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
            {
                settings.Axes[name] = defaults.Axes[name];
            }
        }

        return settings;
    }
}
