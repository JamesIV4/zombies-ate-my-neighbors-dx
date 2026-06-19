using System.Text.Json;

namespace ZamndxLauncher;

/// <summary>
/// A single ROM patch that can be stacked onto the verified source ROM.
/// The base patch is mandatory and always applied first; optional patches are
/// user-toggleable improvements that are applied on top of it in catalog order.
/// </summary>
internal sealed record RomPatch(
    string Id,
    string Name,
    string Description,
    string FileName,
    bool Mandatory,
    bool DefaultEnabled,
    string? ExpectedSha256 = null);

internal static class RomPatchCatalog
{
    /// <summary>The core DX mod. Its IPS is generated at build time.</summary>
    internal static readonly RomPatch Base = new(
        Id: "dx",
        Name: "ZAMN DX core",
        Description: "Bigger hitboxes, analog movement, and twin-stick aiming.",
        FileName: "zamndx.ips",
        Mandatory: true,
        DefaultEnabled: true);

    /// <summary>
    /// Optional, toggleable improvements. Each ships as a committed IPS file in
    /// the bundle's mod directory and is verified against its expected hash
    /// before it is applied.
    /// </summary>
    internal static readonly IReadOnlyList<RomPatch> Optional =
    [
        new RomPatch(
            Id: "widescreen",
            Name: "Widescreen",
            Description: "Extends the playfield for bsnes-hd/HD Mode 7 output. "
                + "Requires the bundled bsnes-hd libretro runtime.",
            FileName: "widescreen.ips",
            Mandatory: false,
            DefaultEnabled: true,
            ExpectedSha256: "53978CB3067E6348617768A1216580C426C44B3398324E60C5B0E62E5B423C72"),
        new RomPatch(
            Id: "bloody",
            Name: "Bloody Disgusting Edition",
            Description: "Restores uncensored red blood on the Game Over screen "
                + "(romhacking.net hack #4306). The transformation monster and all "
                + "other graphics stay untouched.",
            FileName: "bloody-disgusting.ips",
            Mandatory: false,
            DefaultEnabled: true,
            ExpectedSha256: "14C54077012147A146E0FA3EAEF1D2673A2B8493D71C40A126FA2A843E557374"),
        new RomPatch(
            Id: "reverse-cycling",
            Name: "Reverse Inventory Cycling",
            Description: "Cycle weapons and items in both directions "
                + "(romhacking.net hack #4318). Enables the twin-stick-friendly "
                + "control scheme: weapons on the triggers, items on the bumpers.",
            FileName: "reverse-inventory-cycling.ips",
            Mandatory: false,
            DefaultEnabled: true,
            ExpectedSha256: "2CB1E64CFFB4529F6593CEA815E53C9DE4033DB586D0B3E4FBDAEEC4D58E2237"),
        new RomPatch(
            Id: "save",
            Name: "Battery Save",
            Description: "Saves your level, ammo, and item counts to battery SRAM "
                + "after every level (romhacking.net hack #7312). To load, open the "
                + "password screen and press Start. Start a new game first - loading "
                + "with no save yet shows a black screen.",
            FileName: "snes-sram-save.ips",
            Mandatory: false,
            DefaultEnabled: true,
            ExpectedSha256: "4FF05975937E6CDBAC3EC8FA99B3C31F69FB034A198A89A06D2E41E238D0D976"),
    ];

    internal const string ReverseCyclingId = "reverse-cycling";
    internal const string WidescreenId = "widescreen";

    internal static RomPatch ReverseCyclingPatch =>
        Optional.Single(patch => patch.Id == ReverseCyclingId);

    internal static RomPatch WidescreenPatch =>
        Optional.Single(patch => patch.Id == WidescreenId);

    /// <summary>Base first, then optional patches in their declared order.</summary>
    internal static IEnumerable<RomPatch> All => Optional.Prepend(Base);

    internal static bool IsAvailable(RomPatch patch) =>
        File.Exists(AppPaths.BundledPatchPath(patch.FileName));
}

/// <summary>
/// Which optional patches the player has enabled. Stored separately from the
/// controller profile so the two concerns stay independent.
/// </summary>
internal sealed class PatchSettings
{
    public List<string> Enabled { get; set; } = [];
    public List<string> KnownPatchIds { get; set; } = [];

    internal bool IsEnabled(string id) => Enabled.Contains(id);

    internal PatchSettings Clone() => new()
    {
        Enabled = [.. Enabled],
        KnownPatchIds = [.. KnownPatchIds],
    };

    /// <summary>The patch ids to stack, in catalog order: base then optional.</summary>
    internal IReadOnlyList<string> ResolveOrderedIds()
    {
        var ids = new List<string> { RomPatchCatalog.Base.Id };
        foreach (var patch in RomPatchCatalog.Optional)
        {
            if (IsEnabled(patch.Id) && RomPatchCatalog.IsAvailable(patch))
            {
                ids.Add(patch.Id);
            }
        }
        return ids;
    }
}

internal static class PatchSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    internal static PatchSettings Load()
    {
        if (!File.Exists(AppPaths.PatchSettingsPath))
        {
            return CreateDefault();
        }

        try
        {
            var settings = JsonSerializer.Deserialize<PatchSettings>(
                File.ReadAllText(AppPaths.PatchSettingsPath),
                JsonOptions);
            return Normalize(settings ?? CreateDefault(), seedMissingDefaults: true);
        }
        catch
        {
            return CreateDefault();
        }
    }

    internal static void Save(PatchSettings settings)
    {
        Directory.CreateDirectory(AppPaths.UserRoot);
        File.WriteAllText(
            AppPaths.PatchSettingsPath,
            JsonSerializer.Serialize(
                Normalize(settings, seedMissingDefaults: false),
                JsonOptions));
    }

    internal static PatchSettings CreateDefault() => new()
    {
        Enabled =
        [
            .. RomPatchCatalog.Optional
                .Where(patch => patch.DefaultEnabled)
                .Select(patch => patch.Id),
        ],
        KnownPatchIds = [.. RomPatchCatalog.Optional.Select(patch => patch.Id)],
    };

    /// <summary>
    /// Drop unknown ids, keep catalog order, and seed default-on patches that a
    /// saved profile has never seen. This lets new optional defaults turn on
    /// without forgetting a user's deliberate opt-outs for known patches.
    /// </summary>
    internal static PatchSettings Normalize(
        PatchSettings settings,
        bool seedMissingDefaults)
    {
        settings.Enabled ??= [];
        settings.KnownPatchIds ??= [];

        if (seedMissingDefaults)
        {
            var knownPatchIds = settings.KnownPatchIds.ToHashSet(StringComparer.Ordinal);
            foreach (var patch in RomPatchCatalog.Optional)
            {
                if (patch.DefaultEnabled
                    && !knownPatchIds.Contains(patch.Id)
                    && !settings.Enabled.Contains(patch.Id))
                {
                    settings.Enabled.Add(patch.Id);
                }
            }
        }

        settings.Enabled =
        [
            .. RomPatchCatalog.Optional
                .Where(patch => settings.Enabled.Contains(patch.Id))
                .Select(patch => patch.Id),
        ];
        settings.KnownPatchIds = [.. RomPatchCatalog.Optional.Select(patch => patch.Id)];
        return settings;
    }
}
