using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ZamndxLauncher;

internal static class ModRuntime
{
    private const string ExpectedSourceHash = "B27E2E957FA760F4F483E2AF30E03062034A6C0066984F2E284CC2CB430B2059";
    private static readonly string ExpectedPatchedHash = ReadExpectedPatchedHash();

    private static string ReadExpectedPatchedHash()
    {
        var value = typeof(ModRuntime).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .SingleOrDefault(attribute => attribute.Key == "ExpectedPatchedRomHash")
            ?.Value;
        if (string.IsNullOrWhiteSpace(value) || value.Length != 64)
        {
            throw new InvalidOperationException(
                "The launcher was built without a valid patched ROM hash.");
        }
        return value.ToUpperInvariant();
    }

    internal static void Prepare(
        ControllerSettings settings,
        PatchSettings patches,
        IWin32Window owner)
    {
        AppPaths.ValidateBundle(UsesBsnesHdRuntime(patches));
        var bsnesHdCorePath = EnsureBsnesHdCore(patches);
        EnsurePatchedRom(patches, owner);
        Directory.CreateDirectory(AppPaths.RuntimeDirectory);
        File.Copy(AppPaths.BundledLuaPath, AppPaths.RuntimeLuaPath, true);
        WriteLuaConfig(settings);
        EnsureBizHawkConfig(settings, ControlSchemes.ForPatches(patches), bsnesHdCorePath);
        SettingsStore.Save(settings);
    }

    internal static Process StartGame(PatchSettings patches)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = AppPaths.BundledBizHawkPath,
            WorkingDirectory = Path.GetDirectoryName(AppPaths.BundledBizHawkPath)!,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("--fullscreen");
        startInfo.ArgumentList.Add("--chromeless");
        startInfo.ArgumentList.Add("--config");
        startInfo.ArgumentList.Add(AppPaths.BizHawkConfigPath);
        startInfo.ArgumentList.Add("--lua");
        startInfo.ArgumentList.Add(AppPaths.RuntimeLuaPath);
        startInfo.ArgumentList.Add(BuildBizHawkRomArgument(patches));
        return Process.Start(startInfo)
            ?? throw new InvalidOperationException("BizHawk could not be started.");
    }

    internal static bool UsesBsnesHdRuntime(PatchSettings patches) =>
        patches.IsEnabled(RomPatchCatalog.WidescreenId)
        && RomPatchCatalog.IsAvailable(RomPatchCatalog.WidescreenPatch);

    internal static string BuildBizHawkRomArgument(PatchSettings patches)
    {
        if (!UsesBsnesHdRuntime(patches))
        {
            return AppPaths.PatchedRomPath;
        }

        var token = JsonSerializer.Serialize(new LibretroOpenAdvancedToken
        {
            Path = AppPaths.PatchedRomPath,
            CorePath = BsnesHdCorePathFor(patches),
        });
        return "*Libretro*" + token;
    }

    internal static string BsnesHdCorePathFor(PatchSettings patches)
    {
        if (!UsesBsnesHdRuntime(patches))
        {
            return AppPaths.BundledBsnesHdCorePath;
        }

        var aspect = WidescreenAspects.Normalize(patches.WidescreenAspect);
        return aspect.Id == WidescreenAspects.SixteenTenId
            ? AppPaths.RuntimeBsnesHdCorePath(aspect)
            : AppPaths.BundledBsnesHdCorePath;
    }

    private static string EnsureBsnesHdCore(PatchSettings patches)
    {
        var path = BsnesHdCorePathFor(patches);
        if (!UsesBsnesHdRuntime(patches)
            || path == AppPaths.BundledBsnesHdCorePath)
        {
            return path;
        }

        var aspect = WidescreenAspects.Normalize(patches.WidescreenAspect);
        LibretroCoreOptions.PatchDefaultOption(
            AppPaths.BundledBsnesHdCorePath,
            path,
            "bsnes_mode7_widescreen",
            aspect.BsnesOptionValue);
        return path;
    }

    // SNES LoROM checksum/complement live at the end of the first bank. After
    // any optional patch changes ROM bytes the original checksum no longer
    // matches, so it is recomputed once the full stack has been applied.
    private const int ChecksumOffset = 0x7FDC;

    private static void EnsurePatchedRom(PatchSettings patches, IWin32Window owner)
    {
        var desiredIds = patches.ResolveOrderedIds();
        var desiredAspect = ResolveWidescreenAspect(desiredIds, patches);
        if (IsCachedRomCurrent(desiredIds, desiredAspect)
            || TryRetargetCachedWidescreenAspect(desiredIds, desiredAspect))
        {
            return;
        }

        var sourcePath = AppPaths.AdjacentSourceRomPath;
        if (!File.Exists(sourcePath))
        {
            using var dialog = new OpenFileDialog
            {
                Title = "Select the headerless USA Zombies Ate My Neighbors ROM",
                Filter = "SNES ROM (*.sfc;*.smc)|*.sfc;*.smc|All files (*.*)|*.*",
                CheckFileExists = true,
                Multiselect = false,
            };
            if (dialog.ShowDialog(owner) != DialogResult.OK)
            {
                throw new InvalidOperationException(
                    "A legally obtained headerless USA ROM is required.");
            }
            sourcePath = dialog.FileName;
        }

        var actualHash = HashFile(sourcePath);
        if (actualHash != ExpectedSourceHash)
        {
            throw new InvalidOperationException(
                "This is not the supported headerless USA ROM.\n\n"
                + $"Expected SHA-256:\n{ExpectedSourceHash}\n\n"
                + $"Selected ROM SHA-256:\n{actualHash}");
        }

        // Apply the base DX patch first and verify it against the published hash
        // so a corrupt or wrong base patch is always caught, then stack any
        // enabled optional patches on top of the verified DX ROM.
        var rom = IpsPatcher.Apply(
            File.ReadAllBytes(sourcePath),
            File.ReadAllBytes(AppPaths.BundledIpsPath));
        var baseHash = HashBytes(rom);
        if (baseHash != ExpectedPatchedHash)
        {
            throw new InvalidOperationException(
                $"The base DX patch failed verification. Expected {ExpectedPatchedHash}, got {baseHash}.");
        }

        foreach (var patch in RomPatchCatalog.Optional)
        {
            if (!desiredIds.Contains(patch.Id))
            {
                continue;
            }

            var patchPath = AppPaths.BundledPatchPath(patch.FileName);
            if (!File.Exists(patchPath))
            {
                throw new InvalidOperationException(
                    $"The \"{patch.Name}\" improvement is enabled but its patch "
                    + $"file is missing:\n\nmod\\{patch.FileName}");
            }

            var patchBytes = File.ReadAllBytes(patchPath);
            if (patch.ExpectedSha256 is not null
                && HashBytes(patchBytes) != patch.ExpectedSha256)
            {
                throw new InvalidOperationException(
                    $"The \"{patch.Name}\" improvement patch failed its integrity check.");
            }

            rom = IpsPatcher.Apply(rom, patchBytes);
        }

        if (desiredAspect is not null
            && desiredAspect != WidescreenAspects.SixteenNineId)
        {
            ApplyWidescreenCameraClamp(rom, desiredAspect);
        }
        FixSnesChecksum(rom);

        Directory.CreateDirectory(AppPaths.GamesDirectory);
        File.WriteAllBytes(AppPaths.PatchedRomPath, rom);
        WriteManifest(desiredIds, desiredAspect, HashBytes(rom));
    }

    private static bool IsCachedRomCurrent(
        IReadOnlyList<string> desiredIds,
        string? desiredWidescreenAspect)
    {
        if (!File.Exists(AppPaths.PatchedRomPath))
        {
            return false;
        }

        var manifest = ReadManifest();
        if (manifest is not null)
        {
            return manifest.PatchIds.SequenceEqual(desiredIds)
                && string.Equals(
                    NormalizeManifestWidescreenAspect(manifest),
                    desiredWidescreenAspect,
                    StringComparison.Ordinal)
                && HashFile(AppPaths.PatchedRomPath) == manifest.Sha256;
        }

        // Pre-upgrade installs have no manifest. Accept an existing base-only ROM
        // that matches the published DX hash so those users are not re-prompted
        // for their source ROM, and record a manifest for next time.
        if (desiredIds.Count == 1
            && desiredIds[0] == RomPatchCatalog.Base.Id
            && HashFile(AppPaths.PatchedRomPath) == ExpectedPatchedHash)
        {
            WriteManifest(desiredIds, desiredWidescreenAspect, ExpectedPatchedHash);
            return true;
        }

        return false;
    }

    private static bool TryRetargetCachedWidescreenAspect(
        IReadOnlyList<string> desiredIds,
        string? desiredWidescreenAspect)
    {
        if (desiredWidescreenAspect is null || !File.Exists(AppPaths.PatchedRomPath))
        {
            return false;
        }

        var manifest = ReadManifest();
        if (manifest is null
            || !manifest.PatchIds.SequenceEqual(desiredIds)
            || HashFile(AppPaths.PatchedRomPath) != manifest.Sha256)
        {
            return false;
        }

        var currentAspect = NormalizeManifestWidescreenAspect(manifest);
        if (string.Equals(currentAspect, desiredWidescreenAspect, StringComparison.Ordinal))
        {
            return false;
        }

        try
        {
            var rom = File.ReadAllBytes(AppPaths.PatchedRomPath);
            ApplyWidescreenCameraClamp(rom, desiredWidescreenAspect);
            FixSnesChecksum(rom);
            var sha256 = HashBytes(rom);
            File.WriteAllBytes(AppPaths.PatchedRomPath, rom);
            WriteManifest(desiredIds, desiredWidescreenAspect, sha256);
            return true;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    private static string? ResolveWidescreenAspect(
        IReadOnlyList<string> desiredIds,
        PatchSettings patches) =>
        desiredIds.Contains(RomPatchCatalog.WidescreenId)
            ? WidescreenAspects.Normalize(patches.WidescreenAspect).Id
            : null;

    private static string? NormalizeManifestWidescreenAspect(PatchManifest manifest) =>
        manifest.PatchIds.Contains(RomPatchCatalog.WidescreenId)
            ? WidescreenAspects.Normalize(manifest.WidescreenAspect).Id
            : null;

    internal static void ApplyWidescreenCameraClamp(byte[] rom, string? widescreenAspect)
    {
        if (widescreenAspect is null)
        {
            return;
        }

        var aspect = WidescreenAspects.Normalize(widescreenAspect);
        PatchWordAtUniquePattern(
            rom,
            [
                0xAF, 0x6A, 0x1B, 0x00,
                0xC9, null, null,
                0xB0, 0x01, 0x6B,
                0x5C, 0x90, 0xA6, 0x80,
            ],
            valueOffset: 5,
            value: aspect.CameraMarginPixels + 1);
        PatchWordAtUniquePattern(
            rom,
            [
                0xAF, 0x6A, 0x1B, 0x00,
                0x18,
                0x69, null, null,
                0xCF, 0xB8, 0x00, 0x00,
                0x90, 0x01, 0x6B,
                0xAF, 0x6A, 0x1B, 0x00,
                0x5C, 0x12, 0xA7, 0x80,
            ],
            valueOffset: 6,
            value: aspect.CameraMarginPixels);
    }

    private static void PatchWordAtUniquePattern(
        byte[] data,
        byte?[] pattern,
        int valueOffset,
        int value)
    {
        var match = -1;
        for (var index = 0; index <= data.Length - pattern.Length; index++)
        {
            var found = true;
            for (var patternIndex = 0; patternIndex < pattern.Length; patternIndex++)
            {
                if (pattern[patternIndex] is { } expected && data[index + patternIndex] != expected)
                {
                    found = false;
                    break;
                }
            }

            if (!found)
            {
                continue;
            }

            if (match >= 0)
            {
                throw new InvalidOperationException(
                    "The widescreen camera clamp pattern is not unique.");
            }
            match = index;
        }

        if (match < 0)
        {
            throw new InvalidOperationException(
                "The widescreen camera clamp pattern was not found.");
        }

        data[match + valueOffset] = (byte)(value & 0xFF);
        data[match + valueOffset + 1] = (byte)((value >> 8) & 0xFF);
    }

    private static void FixSnesChecksum(byte[] rom)
    {
        if (rom.Length < ChecksumOffset + 4)
        {
            return;
        }

        var checksum = ComputeSnesChecksum(rom);
        var complement = checksum ^ 0xFFFF;

        rom[ChecksumOffset] = (byte)(complement & 0xFF);
        rom[ChecksumOffset + 1] = (byte)((complement >> 8) & 0xFF);
        rom[ChecksumOffset + 2] = (byte)(checksum & 0xFF);
        rom[ChecksumOffset + 3] = (byte)((checksum >> 8) & 0xFF);
    }

    // The stored checksum and its complement always contribute 0x1FE to the byte
    // total, so this is stable with the existing pair present. ROMs whose size is
    // not a power of two (the battery-save patch grows the ROM to 1.5 MB) mirror
    // the trailing region up to the previous power-of-two boundary, matching how
    // the SNES and emulators compute the header checksum.
    internal static int ComputeSnesChecksum(byte[] rom)
    {
        var half = 1;
        while (half * 2 <= rom.Length)
        {
            half *= 2;
        }

        long sum = 0;
        for (var i = 0; i < half; i++)
        {
            sum += rom[i];
        }

        var remainder = rom.Length - half;
        if (remainder > 0)
        {
            long remainderSum = 0;
            for (var i = half; i < rom.Length; i++)
            {
                remainderSum += rom[i];
            }
            sum += remainderSum * (half / remainder);
        }

        return (int)(sum & 0xFFFF);
    }

    private static PatchManifest? ReadManifest()
    {
        if (!File.Exists(AppPaths.PatchManifestPath))
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<PatchManifest>(
                File.ReadAllText(AppPaths.PatchManifestPath));
        }
        catch
        {
            return null;
        }
    }

    private static void WriteManifest(
        IReadOnlyList<string> patchIds,
        string? widescreenAspect,
        string sha256)
    {
        Directory.CreateDirectory(AppPaths.GamesDirectory);
        var manifest = new PatchManifest
        {
            PatchIds = [.. patchIds],
            WidescreenAspect = widescreenAspect,
            Sha256 = sha256,
        };
        File.WriteAllText(
            AppPaths.PatchManifestPath,
            JsonSerializer.Serialize(
                manifest,
                new JsonSerializerOptions { WriteIndented = true }));
    }

    private static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string HashBytes(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data));

    private sealed class PatchManifest
    {
        public string[] PatchIds { get; set; } = [];
        public string? WidescreenAspect { get; set; }
        public string Sha256 { get; set; } = string.Empty;
    }

    internal static void EnsureBizHawkConfig(
        ControllerSettings settings,
        ControlScheme scheme,
        string? libretroCorePath = null)
    {
        Directory.CreateDirectory(AppPaths.BizHawkUserDirectory);

        JsonObject config;
        if (File.Exists(AppPaths.BizHawkConfigPath))
        {
            try
            {
                config = JsonNode.Parse(File.ReadAllText(AppPaths.BizHawkConfigPath))?.AsObject()
                    ?? new JsonObject();
            }
            catch
            {
                config = new JsonObject();
            }
        }
        else
        {
            config = new JsonObject();
        }

        config["FirstBoot"] = false;
        config["SelectedProfile"] = 1;
        config["UpdateAutoCheckEnabled"] = false;
        config["RunInBackground"] = true;
        config["AcceptBackgroundInputControllerOnly"] = true;
        config["LastWrittenFrom"] = "2.11.1";
        config["LastWrittenFromDetailed"] = "Version 2.11.1";
        config["LibretroCore"] = libretroCorePath ?? AppPaths.BundledBsnesHdCorePath;

        // Render through the GPU (Direct3D 11), not BizHawk's GDI+ software blitter.
        // GDI+ CPU-scales the larger widescreen framebuffer to fullscreen every frame,
        // which bogs down weaker hardware even though the core itself runs fine. This
        // must be set explicitly: a prior --gdi launch persists DispMethod=GdiPlus(1)
        // into this config, so dropping the flag alone is not enough. BizHawk falls
        // back D3D11 -> OpenGL -> GDI+ on its own if D3D11 is unavailable.
        // EDispMethod: OpenGL=0, GdiPlus=1, D3D11=2.
        config["DispMethod"] = 2;

        // The battery-save patch persists progress to SRAM. BizHawk only writes
        // SaveRAM to disk on a clean close by default, so flush it periodically
        // (about every ten seconds) and keep a backup so a hard quit cannot lose
        // a save the game just wrote at the end of a level.
        config["FlushSaveRamFrames"] = 600;
        config["BackupSaveram"] = true;

        var commonToolSettings = config["CommonToolSettings"] as JsonObject
            ?? new JsonObject();
        config["CommonToolSettings"] = commonToolSettings;
        var luaConsoleSettings =
            commonToolSettings["BizHawk.Client.EmuHawk.LuaConsole"] as JsonObject
            ?? new JsonObject();
        commonToolSettings["BizHawk.Client.EmuHawk.LuaConsole"] =
            luaConsoleSettings;
        luaConsoleSettings["TopMost"] = false;
        luaConsoleSettings["FloatingWindow"] = false;
        luaConsoleSettings["AutoLoad"] = false;

        var buttonMap = BuildButtonMap(settings, scheme);
        WriteSnesControllerBindings(config, buttonMap);
        WriteLibretroControllerBindings(config, buttonMap);
        WriteBizHawkPathEntries(config);

        File.WriteAllText(
            AppPaths.BizHawkConfigPath,
            config.ToJsonString(new JsonSerializerOptions { WriteIndented = true }),
            new UTF8Encoding(false));
    }

    // Map the active control scheme onto BizHawk's own SNES gamepad bindings so
    // the emulator drives every button natively. A host control listed under
    // several SNES buttons is a combo; comma-separated controls OR together.
    // Buttons with no host are cleared so BizHawk's defaults cannot leak in.
    private static void WriteSnesControllerBindings(
        JsonObject config,
        Dictionary<string, List<string>> buttonMap)
    {
        var controllers = config["AllTrollers"] as JsonObject ?? new JsonObject();
        config["AllTrollers"] = controllers;
        var snes = controllers["SNES Controller"] as JsonObject ?? new JsonObject();
        controllers["SNES Controller"] = snes;

        foreach (var snesButton in ControlSchemes.SnesButtons)
        {
            snes[$"P1 {snesButton}"] = string.Join(", ", buttonMap[snesButton]);
        }
    }

    private static void WriteLibretroControllerBindings(
        JsonObject config,
        Dictionary<string, List<string>> buttonMap)
    {
        var controllers = config["AllTrollers"] as JsonObject ?? new JsonObject();
        config["AllTrollers"] = controllers;
        var libretro = controllers["LibRetro Controls"] as JsonObject ?? new JsonObject();
        controllers["LibRetro Controls"] = libretro;

        foreach (var snesButton in ControlSchemes.SnesButtons)
        {
            libretro[$"P1 RetroPad {snesButton}"] = string.Join(", ", buttonMap[snesButton]);
        }

        foreach (var unusedButton in new[] { "L2", "R2", "L3", "R3" })
        {
            libretro[$"P1 RetroPad {unusedButton}"] = string.Empty;
        }
    }

    /// <summary>
    /// Invert the action bindings into one host list per SNES button. A host
    /// appearing under several SNES buttons is a combo (for example a trigger
    /// that presses the cycle button plus the reverse modifier); several hosts
    /// under one SNES button means any of them triggers it.
    /// </summary>
    internal static Dictionary<string, List<string>> BuildButtonMap(
        ControllerSettings settings, ControlScheme scheme)
    {
        var snesHosts = ControlSchemes.SnesButtons.ToDictionary(name => name, _ => new List<string>());
        foreach (var action in scheme.Actions)
        {
            if (!settings.Bindings.TryGetValue(action.Id, out var host) || string.IsNullOrWhiteSpace(host))
            {
                continue;
            }

            var qualified = $"{settings.Device} {host}";
            foreach (var snes in action.SnesTargets)
            {
                if (snesHosts.TryGetValue(snes, out var hosts) && !hosts.Contains(qualified))
                {
                    hosts.Add(qualified);
                }
            }
        }
        return snesHosts;
    }

    private static void WriteBizHawkPathEntries(JsonObject config)
    {
        Directory.CreateDirectory(AppPaths.BizHawkLibretroCoresDirectory);
        Directory.CreateDirectory(AppPaths.BizHawkLibretroSystemDirectory);
        Directory.CreateDirectory(AppPaths.BizHawkLibretroSaveRamDirectory);

        var pathEntries = config["PathEntries"] as JsonObject ?? new JsonObject();
        config["PathEntries"] = pathEntries;

        var paths = pathEntries["Paths"] as JsonArray ?? new JsonArray();
        pathEntries["Paths"] = paths;
        pathEntries["UseRecentForRoms"] = false;
        pathEntries["LastRomPath"] = AppPaths.GamesDirectory;

        UpsertPath(paths, "Libretro", "Base", AppPaths.BizHawkLibretroDirectory);
        UpsertPath(paths, "Libretro", "Cores", AppPaths.BizHawkLibretroCoresDirectory);
        UpsertPath(paths, "Libretro", "System", AppPaths.BizHawkLibretroSystemDirectory);
        UpsertPath(paths, "Libretro", "Save RAM", AppPaths.BizHawkLibretroSaveRamDirectory);
    }

    private static void UpsertPath(JsonArray paths, string system, string type, string path)
    {
        for (var index = paths.Count - 1; index >= 0; index--)
        {
            if (paths[index] is not JsonObject entry)
            {
                continue;
            }

            if (string.Equals((string?)entry["System"], system, StringComparison.Ordinal)
                && string.Equals((string?)entry["Type"], type, StringComparison.Ordinal))
            {
                paths.RemoveAt(index);
            }
        }

        paths.Add(new JsonObject
        {
            ["Type"] = type,
            ["Path"] = Path.GetFullPath(path),
            ["System"] = system,
        });
    }

    private static void WriteLuaConfig(ControllerSettings settings)
    {
        static string Quote(string value)
        {
            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }

        // Buttons are handled by BizHawk's own config; the runtime only needs the
        // stick axes plus device, deadzone, and inversion.
        var text = new StringBuilder();
        text.AppendLine("return {");
        text.AppendLine($"\tdevice = {Quote(settings.Device)},");
        text.AppendLine($"\tdeadzone = {settings.Deadzone.ToString(CultureInfo.InvariantCulture)},");
        text.AppendLine($"\tinvert_left_y = {(!settings.InvertLeftY).ToString().ToLowerInvariant()},");
        text.AppendLine($"\tinvert_right_y = {(!settings.InvertRightY).ToString().ToLowerInvariant()},");
        text.AppendLine("\tenabled = true,");
        text.AppendLine("\taxes = {");
        foreach (var name in ControllerSettings.AxisOrder)
        {
            text.AppendLine($"\t\t{name} = {Quote($"{settings.Device} {settings.Axes[name]}")},");
        }
        text.AppendLine("\t},");
        text.AppendLine("}");
        File.WriteAllText(AppPaths.RuntimeConfigPath, text.ToString(), new UTF8Encoding(false));
    }

    private sealed class LibretroOpenAdvancedToken
    {
        public string Path { get; set; } = string.Empty;
        public string CorePath { get; set; } = string.Empty;
    }
}

internal static class IpsPatcher
{
    internal static void Apply(string romPath, string patchPath, string outputPath)
    {
        var patched = Apply(File.ReadAllBytes(romPath), File.ReadAllBytes(patchPath));
        File.WriteAllBytes(outputPath, patched);
    }

    internal static byte[] Apply(byte[] source, byte[] patch)
    {
        var rom = source.ToList();
        if (patch.Length < 8 || Encoding.ASCII.GetString(patch, 0, 5) != "PATCH")
        {
            throw new InvalidOperationException("The bundled IPS patch is invalid.");
        }

        var position = 5;
        while (position + 3 <= patch.Length)
        {
            if (Encoding.ASCII.GetString(patch, position, 3) == "EOF")
            {
                break;
            }

            var offset = (patch[position] << 16)
                | (patch[position + 1] << 8)
                | patch[position + 2];
            position += 3;
            var size = (patch[position] << 8) | patch[position + 1];
            position += 2;

            byte[] replacement;
            if (size == 0)
            {
                size = (patch[position] << 8) | patch[position + 1];
                var value = patch[position + 2];
                position += 3;
                replacement = Enumerable.Repeat(value, size).ToArray();
            }
            else
            {
                if (position + size > patch.Length)
                {
                    throw new InvalidOperationException("The bundled IPS patch ends unexpectedly.");
                }
                replacement = patch[position..(position + size)];
                position += size;
            }

            while (rom.Count < offset + size)
            {
                rom.Add(0);
            }
            for (var index = 0; index < size; index++)
            {
                rom[offset + index] = replacement[index];
            }
        }

        return [.. rom];
    }
}
