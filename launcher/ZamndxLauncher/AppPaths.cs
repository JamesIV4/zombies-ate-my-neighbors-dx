namespace ZamndxLauncher;

internal static class AppPaths
{
    internal const string SourceRomName = "Zombies Ate My Neighbors (USA).sfc";
    internal const string PatchedRomName = "Zombies Ate My Neighbors DX.sfc";

    internal static readonly string BundleRoot = AppContext.BaseDirectory;
    internal static readonly string UserRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ZAMNDX");
    internal static readonly string SettingsPath = Path.Combine(UserRoot, "controller.json");
    internal static readonly string GamesDirectory = Path.Combine(UserRoot, "Games");
    internal static readonly string PatchedRomPath = Path.Combine(GamesDirectory, PatchedRomName);
    internal static readonly string RuntimeDirectory = Path.Combine(UserRoot, "Runtime");
    internal static readonly string RuntimeLuaPath = Path.Combine(RuntimeDirectory, "zamndx.lua");
    internal static readonly string RuntimeConfigPath = Path.Combine(RuntimeDirectory, "zamndx-controller-config.lua");
    internal static readonly string BizHawkUserDirectory = Path.Combine(UserRoot, "BizHawk");
    internal static readonly string BizHawkConfigPath = Path.Combine(BizHawkUserDirectory, "config.ini");

    internal static readonly string BundledIpsPath = Path.Combine(BundleRoot, "mod", "zamndx.ips");
    internal static readonly string BundledLuaPath = Path.Combine(BundleRoot, "mod", "zamndx.lua");
    internal static readonly string BundledBizHawkPath = Path.Combine(
        BundleRoot,
        "runtime",
        "BizHawk",
        "EmuHawk.exe");
    internal static readonly string AdjacentSourceRomPath = Path.Combine(BundleRoot, SourceRomName);

    internal static void ValidateBundle()
    {
        var missing = new List<string>();
        if (!File.Exists(BundledIpsPath)) missing.Add("mod\\zamndx.ips");
        if (!File.Exists(BundledLuaPath)) missing.Add("mod\\zamndx.lua");
        if (!File.Exists(BundledBizHawkPath)) missing.Add("runtime\\BizHawk\\EmuHawk.exe");

        if (missing.Count > 0)
        {
            throw new InvalidOperationException(
                "The release is incomplete. Missing:\n\n" + string.Join("\n", missing));
        }
    }
}
