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
    internal static readonly string PatchSettingsPath = Path.Combine(UserRoot, "patches.json");
    internal static readonly string GamesDirectory = Path.Combine(UserRoot, "Games");
    internal static readonly string PatchedRomPath = Path.Combine(GamesDirectory, PatchedRomName);
    internal static readonly string PatchManifestPath = Path.Combine(GamesDirectory, "patched.json");
    internal static readonly string RuntimeDirectory = Path.Combine(UserRoot, "Runtime");
    internal static readonly string RuntimeLuaPath = Path.Combine(RuntimeDirectory, "zamndx.lua");
    internal static readonly string RuntimeConfigPath = Path.Combine(RuntimeDirectory, "zamndx-controller-config.lua");
    internal static readonly string BizHawkUserDirectory = Path.Combine(UserRoot, "BizHawk");
    internal static readonly string BizHawkConfigPath = Path.Combine(BizHawkUserDirectory, "config.ini");
    internal static readonly string BizHawkLibretroDirectory = Path.Combine(BizHawkUserDirectory, "Libretro");
    internal static readonly string BizHawkLibretroCoresDirectory = Path.Combine(BizHawkLibretroDirectory, "Cores");
    internal static readonly string BizHawkLibretroSystemDirectory = Path.Combine(BizHawkLibretroDirectory, "System");
    internal static readonly string BizHawkLibretroSaveRamDirectory = Path.Combine(BizHawkLibretroDirectory, "SaveRAM");

    internal static readonly string ModDirectory = Path.Combine(BundleRoot, "mod");
    internal static readonly string BundledIpsPath = Path.Combine(ModDirectory, "zamndx.ips");
    internal static readonly string BundledLuaPath = Path.Combine(ModDirectory, "zamndx.lua");

    internal static string BundledPatchPath(string fileName) =>
        Path.Combine(ModDirectory, fileName);

    internal static readonly string BundledBizHawkPath = Path.Combine(
        BundleRoot,
        "runtime",
        "BizHawk",
        "EmuHawk.exe");
    internal static readonly string BundledBizHawkDirectory =
        Path.GetDirectoryName(BundledBizHawkPath)!;
    internal static readonly string BundledBsnesHdCorePath = Path.Combine(
        BundledBizHawkDirectory,
        "Libretro",
        "Cores",
        "bsnes_hd_beta_zamndx_libretro.dll");
    internal static readonly string AdjacentSourceRomPath = Path.Combine(BundleRoot, SourceRomName);

    internal static void ValidateBundle(bool requireBsnesHdCore)
    {
        var missing = new List<string>();
        if (!File.Exists(BundledIpsPath)) missing.Add("mod\\zamndx.ips");
        if (!File.Exists(BundledLuaPath)) missing.Add("mod\\zamndx.lua");
        if (!File.Exists(BundledBizHawkPath)) missing.Add("runtime\\BizHawk\\EmuHawk.exe");
        if (requireBsnesHdCore && !File.Exists(BundledBsnesHdCorePath))
        {
            missing.Add("runtime\\BizHawk\\Libretro\\Cores\\bsnes_hd_beta_zamndx_libretro.dll");
        }

        if (missing.Count > 0)
        {
            throw new InvalidOperationException(
                "The release is incomplete. Missing:\n\n" + string.Join("\n", missing));
        }
    }
}
