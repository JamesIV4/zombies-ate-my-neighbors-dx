using ZamndxLauncher;
using System.Reflection;

var failures = new List<string>();

void Check(bool condition, string name)
{
    if (!condition)
    {
        failures.Add(name);
    }
}

var neutral = new ControllerState(true, 1, 0, 0, 0, 0, 0, 0, 0);
Check(XInput.IsNeutral(neutral), "neutral state");

var faceButton = neutral with { Buttons = 0x1000 };
Check(XInput.DetectButton(faceButton) == "A", "A button detection");

var trigger = neutral with { LeftTrigger = 180 };
Check(XInput.DetectButton(trigger) == "LeftTrigger", "left trigger detection");

var axis = neutral with { RightThumbX = 22000 };
Check(XInput.DetectAxis(axis) == "RightThumbX Axis", "right X axis detection");

var settings = ControllerSettings.CreateDefault();
var clone = settings.Clone();
clone.Buttons["Y"] = "B";
Check(settings.Buttons["Y"] == "X", "settings clone isolation");

Check(RomPatchCatalog.Base is { Mandatory: true, Id: "dx" }, "base patch is mandatory");
var bloody = RomPatchCatalog.Optional.SingleOrDefault(patch => patch.Id == "bloody");
Check(bloody is { Mandatory: false, DefaultEnabled: true }, "bloody patch optional and default on");
Check(
    bloody?.ExpectedSha256 is { Length: 64 } hash && hash.All(Uri.IsHexDigit),
    "bloody patch has an integrity hash");
Check(RomPatchCatalog.All.First() == RomPatchCatalog.Base, "base patch applied first");

var patchSettings = new PatchSettings { Enabled = ["bloody", "unknown", "bloody"] };
var patchClone = patchSettings.Clone();
patchClone.Enabled.Add("dx");
Check(patchSettings.Enabled.Count == 3, "patch settings clone isolation");
Check(
    patchSettings.ResolveOrderedIds().First() == "dx",
    "resolved patch ids start with the base patch");

var patchedRomHash = typeof(ModRuntime).Assembly
    .GetCustomAttributes<AssemblyMetadataAttribute>()
    .SingleOrDefault(attribute => attribute.Key == "ExpectedPatchedRomHash")
    ?.Value;
Check(
    patchedRomHash is not null
        && patchedRomHash.Length == 64
        && patchedRomHash.All(Uri.IsHexDigit),
    "patched ROM hash build metadata");
var expectedPatchedRomHash = Environment.GetEnvironmentVariable(
    "ZAMNDX_EXPECTED_PATCHED_ROM_HASH");
if (!string.IsNullOrWhiteSpace(expectedPatchedRomHash))
{
    Check(
        patchedRomHash == expectedPatchedRomHash,
        "patched ROM hash MSBuild injection");
}

ModRuntime.EnsureBizHawkConfig();
var bizHawkConfig = File.ReadAllText(AppPaths.BizHawkConfigPath);
Check(bizHawkConfig.Contains("\"FirstBoot\": false"), "BizHawk onboarding disabled");
Check(
    bizHawkConfig.Contains("\"AcceptBackgroundInputControllerOnly\": true"),
    "BizHawk controller background input enabled");
Check(
    bizHawkConfig.Contains("\"FloatingWindow\": false"),
    "BizHawk Lua console attached to main window");
Check(
    bizHawkConfig.Contains("\"TopMost\": false"),
    "BizHawk Lua console topmost disabled");
Check(WindowTools.IsLuaConsoleTitle("Lua Console"), "Lua console title detection");
Check(WindowTools.IsLuaConsoleTitle("lua console"), "Lua console title detection case");
Check(!WindowTools.IsLuaConsoleTitle("Zombies Ate My Neighbors"), "game window title detection");

var temporaryDirectory = Path.Combine(Path.GetTempPath(), $"zamndx-tests-{Guid.NewGuid():N}");
Directory.CreateDirectory(temporaryDirectory);
try
{
    var romPath = Path.Combine(temporaryDirectory, "source.sfc");
    var patchPath = Path.Combine(temporaryDirectory, "test.ips");
    var outputPath = Path.Combine(temporaryDirectory, "output.sfc");
    File.WriteAllBytes(romPath, [0x10, 0x20, 0x30, 0x40]);
    File.WriteAllBytes(
        patchPath,
        [
            (byte)'P', (byte)'A', (byte)'T', (byte)'C', (byte)'H',
            0x00, 0x00, 0x01,
            0x00, 0x02,
            0xAA, 0xBB,
            (byte)'E', (byte)'O', (byte)'F',
        ]);
    IpsPatcher.Apply(romPath, patchPath, outputPath);
    var expected = new byte[] { 0x10, 0xAA, 0xBB, 0x40 };
    Check(
        File.ReadAllBytes(outputPath).SequenceEqual(expected),
        "IPS patch application");
    Check(
        IpsPatcher.Apply(File.ReadAllBytes(romPath), File.ReadAllBytes(patchPath))
            .SequenceEqual(expected),
        "in-memory IPS patch application");
}
finally
{
    Directory.Delete(temporaryDirectory, true);
}

if (failures.Count > 0)
{
    Console.Error.WriteLine("Launcher tests failed:");
    foreach (var failure in failures)
    {
        Console.Error.WriteLine($"- {failure}");
    }
    return 1;
}

Console.WriteLine("Launcher tests passed.");
return 0;
