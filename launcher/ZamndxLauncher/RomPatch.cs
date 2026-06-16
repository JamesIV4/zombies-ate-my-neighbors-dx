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
            Id: "bloody",
            Name: "Bloody Disgusting Edition",
            Description: "Restores uncensored red blood on the Game Over screen "
                + "(romhacking.net hack #4306). The transformation monster and all "
                + "other graphics stay untouched.",
            FileName: "bloody-disgusting.ips",
            Mandatory: false,
            DefaultEnabled: true,
            ExpectedSha256: "14C54077012147A146E0FA3EAEF1D2673A2B8493D71C40A126FA2A843E557374"),
    ];

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

    internal bool IsEnabled(string id) => Enabled.Contains(id);

    internal PatchSettings Clone() => new() { Enabled = [.. Enabled] };

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
            return Normalize(settings ?? CreateDefault());
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
            JsonSerializer.Serialize(Normalize(settings), JsonOptions));
    }

    private static PatchSettings CreateDefault() => new()
    {
        Enabled =
        [
            .. RomPatchCatalog.Optional
                .Where(patch => patch.DefaultEnabled)
                .Select(patch => patch.Id),
        ],
    };

    /// <summary>Drop unknown ids and keep them in catalog order without duplicates.</summary>
    private static PatchSettings Normalize(PatchSettings settings)
    {
        settings.Enabled ??= [];
        settings.Enabled =
        [
            .. RomPatchCatalog.Optional
                .Where(patch => settings.Enabled.Contains(patch.Id))
                .Select(patch => patch.Id),
        ];
        return settings;
    }
}
