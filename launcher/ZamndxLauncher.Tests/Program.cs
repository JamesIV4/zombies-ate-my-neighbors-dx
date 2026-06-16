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
clone.Bindings["fire"] = "B";
Check(settings.Bindings["fire"] == "X", "settings clone isolation");
Check(settings.Bindings["use_item"] == "Y", "stock use-item default binding");

var stock = ControlSchemes.Stock;
var reverse = ControlSchemes.ReverseCycling;
Check(stock.Actions.Any(a => a.Id == "change_weapon"), "stock scheme has change weapon");
Check(
    reverse.Actions.Single(a => a.Id == "weapon_prev").SnesTargets.SequenceEqual(new[] { "B", "L" }),
    "weapon previous presses cycle + reverse modifier");
Check(
    reverse.Actions.Single(a => a.Id == "weapon_next").DefaultHost == "RightTrigger",
    "weapon next defaults to the right trigger");
Check(
    ControlSchemes.ForPatches(new PatchSettings { Enabled = [] }) == ControlSchemes.Stock,
    "no reverse patch keeps stock scheme");
Check(
    ControlSchemes.AllActions.All(a => settings.Bindings.ContainsKey(a.Id)),
    "default bindings cover every action");

var reverseMap = ModRuntime.BuildButtonMap(settings, reverse);
Check(
    reverseMap["B"].SequenceEqual(new[] { "X1 RightTrigger", "X1 LeftTrigger" }),
    "weapon cycle driven by both triggers");
Check(
    reverseMap["L"].SequenceEqual(new[] { "X1 LeftTrigger", "X1 LeftShoulder" }),
    "reverse modifier driven by LT and LB");
Check(
    reverseMap["A"].SequenceEqual(new[] { "X1 RightShoulder", "X1 LeftShoulder" }),
    "item cycle driven by both bumpers");
Check(
    reverseMap["Y"].SequenceEqual(new[] { "X1 X", "X1 A" }),
    "fire driven by west and south face buttons");
Check(reverseMap["R"].SequenceEqual(new[] { "X1 B" }), "map driven by east face button");
Check(reverseMap["X"].SequenceEqual(new[] { "X1 Y" }), "use item driven by north face button");
Check(reverseMap["Select"].Count == 0, "select unused in reverse scheme");

var stockMap = ModRuntime.BuildButtonMap(settings, stock);
Check(stockMap["B"].SequenceEqual(new[] { "X1 A" }), "stock change weapon on physical A");
Check(stockMap["L"].SequenceEqual(new[] { "X1 LeftShoulder" }), "stock radar on left bumper");

Check(RomPatchCatalog.Base is { Mandatory: true, Id: "dx" }, "base patch is mandatory");
var reverseCycling = RomPatchCatalog.Optional.SingleOrDefault(patch => patch.Id == "reverse-cycling");
Check(reverseCycling is { Mandatory: false } && reverseCycling.ExpectedSha256?.Length == 64,
    "reverse-cycling patch registered with integrity hash");
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

ModRuntime.EnsureBizHawkConfig(ControllerSettings.CreateDefault(), ControlSchemes.ReverseCycling);
var bizHawkConfig = File.ReadAllText(AppPaths.BizHawkConfigPath);
Check(bizHawkConfig.Contains("\"FirstBoot\": false"), "BizHawk onboarding disabled");
Check(
    bizHawkConfig.Contains("\"P1 B\": \"X1 RightTrigger, X1 LeftTrigger\""),
    "BizHawk SNES weapon cycle bound to both triggers");
Check(
    bizHawkConfig.Contains("\"P1 R\": \"X1 B\""),
    "BizHawk SNES radar bound to the east face button");
Check(
    bizHawkConfig.Contains("\"P1 Select\": \"\""),
    "BizHawk SNES select cleared so defaults cannot leak");
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
