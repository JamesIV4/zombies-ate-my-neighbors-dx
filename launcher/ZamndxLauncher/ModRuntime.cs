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

    internal static void Prepare(ControllerSettings settings, IWin32Window owner)
    {
        AppPaths.ValidateBundle();
        EnsurePatchedRom(owner);
        Directory.CreateDirectory(AppPaths.RuntimeDirectory);
        File.Copy(AppPaths.BundledLuaPath, AppPaths.RuntimeLuaPath, true);
        WriteLuaConfig(settings);
        EnsureBizHawkConfig();
        SettingsStore.Save(settings);
    }

    internal static Process StartGame()
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = AppPaths.BundledBizHawkPath,
            WorkingDirectory = Path.GetDirectoryName(AppPaths.BundledBizHawkPath)!,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("--gdi");
        startInfo.ArgumentList.Add("--fullscreen");
        startInfo.ArgumentList.Add("--chromeless");
        startInfo.ArgumentList.Add("--config");
        startInfo.ArgumentList.Add(AppPaths.BizHawkConfigPath);
        startInfo.ArgumentList.Add("--lua");
        startInfo.ArgumentList.Add(AppPaths.RuntimeLuaPath);
        startInfo.ArgumentList.Add(AppPaths.PatchedRomPath);
        return Process.Start(startInfo)
            ?? throw new InvalidOperationException("BizHawk could not be started.");
    }

    private static void EnsurePatchedRom(IWin32Window owner)
    {
        if (File.Exists(AppPaths.PatchedRomPath)
            && HashFile(AppPaths.PatchedRomPath) == ExpectedPatchedHash)
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

        Directory.CreateDirectory(AppPaths.GamesDirectory);
        IpsPatcher.Apply(sourcePath, AppPaths.BundledIpsPath, AppPaths.PatchedRomPath);
        var patchedHash = HashFile(AppPaths.PatchedRomPath);
        if (patchedHash != ExpectedPatchedHash)
        {
            File.Delete(AppPaths.PatchedRomPath);
            throw new InvalidOperationException(
                $"The patched ROM failed verification. Expected {ExpectedPatchedHash}, got {patchedHash}.");
        }
    }

    private static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    internal static void EnsureBizHawkConfig()
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

        File.WriteAllText(
            AppPaths.BizHawkConfigPath,
            config.ToJsonString(new JsonSerializerOptions { WriteIndented = true }),
            new UTF8Encoding(false));
    }

    private static void WriteLuaConfig(ControllerSettings settings)
    {
        static string Quote(string value)
        {
            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }

        var text = new StringBuilder();
        text.AppendLine("return {");
        text.AppendLine($"\tdevice = {Quote(settings.Device)},");
        text.AppendLine($"\tdeadzone = {settings.Deadzone.ToString(CultureInfo.InvariantCulture)},");
        text.AppendLine($"\tinvert_left_y = {(!settings.InvertLeftY).ToString().ToLowerInvariant()},");
        text.AppendLine($"\tinvert_right_y = {(!settings.InvertRightY).ToString().ToLowerInvariant()},");
        text.AppendLine("\tenabled = true,");
        text.AppendLine("\tbuttons = {");
        foreach (var name in ControllerSettings.ButtonOrder)
        {
            text.AppendLine($"\t\t{name} = {Quote($"{settings.Device} {settings.Buttons[name]}")},");
        }
        text.AppendLine("\t},");
        text.AppendLine("\taxes = {");
        foreach (var name in ControllerSettings.AxisOrder)
        {
            text.AppendLine($"\t\t{name} = {Quote($"{settings.Device} {settings.Axes[name]}")},");
        }
        text.AppendLine("\t},");
        text.AppendLine("}");
        File.WriteAllText(AppPaths.RuntimeConfigPath, text.ToString(), new UTF8Encoding(false));
    }
}

internal static class IpsPatcher
{
    internal static void Apply(string romPath, string patchPath, string outputPath)
    {
        var rom = File.ReadAllBytes(romPath).ToList();
        var patch = File.ReadAllBytes(patchPath);
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

        File.WriteAllBytes(outputPath, [.. rom]);
    }
}
