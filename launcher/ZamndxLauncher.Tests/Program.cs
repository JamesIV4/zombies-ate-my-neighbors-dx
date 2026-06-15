using ZamndxLauncher;

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

ModRuntime.EnsureBizHawkConfig();
var bizHawkConfig = File.ReadAllText(AppPaths.BizHawkConfigPath);
Check(bizHawkConfig.Contains("\"FirstBoot\": false"), "BizHawk onboarding disabled");
Check(
    bizHawkConfig.Contains("\"AcceptBackgroundInputControllerOnly\": true"),
    "BizHawk controller background input enabled");

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
    Check(
        File.ReadAllBytes(outputPath).SequenceEqual(new byte[] { 0x10, 0xAA, 0xBB, 0x40 }),
        "IPS patch application");
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
