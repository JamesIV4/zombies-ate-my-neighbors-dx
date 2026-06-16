namespace ZamndxLauncher;

/// <summary>
/// One bindable in-game action. The player assigns a host control to it; the
/// action drives one or more SNES buttons. Driving several SNES buttons at once
/// expresses a button combo (for example "Weapon previous" presses the weapon
/// cycle button together with the reverse-direction modifier).
/// </summary>
internal sealed record ControlAction(
    string Id,
    string Label,
    string DefaultHost,
    IReadOnlyList<string> SnesTargets);

/// <summary>
/// A complete controller layout. Which scheme is active depends on whether the
/// Reverse Inventory Cycling patch is enabled, so the configuration screen and
/// the Lua runtime always agree with the ROM that is actually built.
/// </summary>
internal sealed record ControlScheme(string Id, string Name, IReadOnlyList<ControlAction> Actions);

internal static class ControlSchemes
{
    // SNES auto-joypad order used when emitting the Lua mapping.
    internal static readonly string[] SnesButtons =
    [
        "Up", "Down", "Left", "Right", "Start", "Select",
        "Y", "B", "A", "X", "L", "R",
    ];

    // Movement and pause are identical in every scheme.
    private static readonly ControlAction[] Common =
    [
        new("move_up", "Move up", "DpadUp", ["Up"]),
        new("move_down", "Move down", "DpadDown", ["Down"]),
        new("move_left", "Move left", "DpadLeft", ["Left"]),
        new("move_right", "Move right", "DpadRight", ["Right"]),
        new("pause", "Pause", "Start", ["Start"]),
    ];

    /// <summary>
    /// Stock Zombies Ate My Neighbors controls, with the labels corrected to the
    /// game's real functions. SNES Y fires (confirmed by the aim hook), SNES B
    /// changes weapon, SNES A changes the special item, SNES X uses the item, and
    /// SNES L/R toggle the radar.
    /// </summary>
    internal static readonly ControlScheme Stock = new(
        "stock",
        "Stock controls",
        [
            .. Common,
            new("fire", "Fire weapon", "X", ["Y"]),
            new("change_weapon", "Change weapon", "A", ["B"]),
            new("change_item", "Change item", "B", ["A"]),
            new("use_item", "Use item", "Y", ["X"]),
            new("radar_left", "Radar on/off", "LeftShoulder", ["L"]),
            new("radar_right", "Radar on/off", "RightShoulder", ["R"]),
        ]);

    /// <summary>
    /// Twin-stick scheme used when Reverse Inventory Cycling is enabled. The patch
    /// turns SNES L into a "reverse direction" modifier, so cycling backwards is
    /// the cycle button pressed together with SNES L.
    /// </summary>
    internal static readonly ControlScheme ReverseCycling = new(
        "reverse-cycling",
        "Revised cycling",
        [
            .. Common,
            new("weapon_next", "Weapon next", "RightTrigger", ["B"]),
            new("weapon_prev", "Weapon previous", "LeftTrigger", ["B", "L"]),
            new("item_next", "Item next", "RightShoulder", ["A"]),
            new("item_prev", "Item previous", "LeftShoulder", ["A", "L"]),
            new("fire_west", "Fire weapon", "X", ["Y"]),
            new("fire_south", "Fire weapon", "A", ["Y"]),
            new("use_item", "Use item", "Y", ["X"]),
            new("map", "Radar / Map", "B", ["R"]),
        ]);

    internal static readonly IReadOnlyList<ControlScheme> All = [Stock, ReverseCycling];

    /// <summary>The scheme that matches the currently selected ROM patches.</summary>
    internal static ControlScheme ForPatches(PatchSettings patches)
    {
        return patches.IsEnabled(RomPatchCatalog.ReverseCyclingId)
            && RomPatchCatalog.IsAvailable(RomPatchCatalog.ReverseCyclingPatch)
                ? ReverseCycling
                : Stock;
    }

    /// <summary>Every action id across all schemes, used to normalise saved bindings.</summary>
    internal static IEnumerable<ControlAction> AllActions =>
        All.SelectMany(scheme => scheme.Actions)
            .GroupBy(action => action.Id)
            .Select(group => group.First());
}
