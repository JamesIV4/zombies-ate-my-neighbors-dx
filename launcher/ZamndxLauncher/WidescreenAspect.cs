namespace ZamndxLauncher;

internal sealed record WidescreenAspectOption(
    string Id,
    string DisplayName,
    int CameraMarginPixels,
    string BsnesOptionValue,
    string CoreFileSuffix)
{
    public override string ToString() => DisplayName;
}

internal static class WidescreenAspects
{
    internal const string SixteenNineId = "16:9";
    internal const string SixteenTenId = "16:10";

    // The widescreen hook is tuned around a 256x224 SNES frame. 16:9 exposes
    // about 71 px/side and uses the existing 8-tile camera margin. 16:10 exposes
    // about 51 px/side; visual testing showed a 6-tile margin hides one real
    // level-data column, so the 16:10 clamp is loosened to 5 tiles.
    internal static readonly WidescreenAspectOption SixteenNine = new(
        SixteenNineId,
        "16:9",
        CameraMarginPixels: 64,
        BsnesOptionValue: "16:9",
        CoreFileSuffix: "16x9");

    internal static readonly WidescreenAspectOption SixteenTen = new(
        SixteenTenId,
        "16:10",
        CameraMarginPixels: 40,
        BsnesOptionValue: "16:10",
        CoreFileSuffix: "16x10");

    internal static readonly IReadOnlyList<WidescreenAspectOption> All =
    [
        SixteenNine,
        SixteenTen,
    ];

    internal static WidescreenAspectOption Normalize(string? id) =>
        All.FirstOrDefault(aspect => string.Equals(aspect.Id, id, StringComparison.Ordinal))
            ?? SixteenNine;
}
