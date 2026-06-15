using System.Runtime.InteropServices;

namespace ZamndxLauncher;

[StructLayout(LayoutKind.Sequential)]
internal struct XInputGamepad
{
    internal ushort Buttons;
    internal byte LeftTrigger;
    internal byte RightTrigger;
    internal short LeftThumbX;
    internal short LeftThumbY;
    internal short RightThumbX;
    internal short RightThumbY;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XInputNativeState
{
    internal uint PacketNumber;
    internal XInputGamepad Gamepad;
}

internal readonly record struct ControllerState(
    bool Connected,
    uint PacketNumber,
    ushort Buttons,
    byte LeftTrigger,
    byte RightTrigger,
    short LeftThumbX,
    short LeftThumbY,
    short RightThumbX,
    short RightThumbY);

internal static class XInput
{
    [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")]
    private static extern uint GetState14(uint userIndex, out XInputNativeState state);

    [DllImport("xinput9_1_0.dll", EntryPoint = "XInputGetState")]
    private static extern uint GetState910(uint userIndex, out XInputNativeState state);

    internal static ControllerState Read(int slot)
    {
        XInputNativeState native;
        uint result;
        try
        {
            result = GetState14((uint)slot, out native);
        }
        catch (DllNotFoundException)
        {
            result = GetState910((uint)slot, out native);
        }

        if (result != 0)
        {
            return default;
        }

        return new ControllerState(
            true,
            native.PacketNumber,
            native.Gamepad.Buttons,
            native.Gamepad.LeftTrigger,
            native.Gamepad.RightTrigger,
            native.Gamepad.LeftThumbX,
            native.Gamepad.LeftThumbY,
            native.Gamepad.RightThumbX,
            native.Gamepad.RightThumbY);
    }

    internal static bool IsNeutral(ControllerState state)
    {
        return state.Connected
            && state.Buttons == 0
            && state.LeftTrigger < 40
            && state.RightTrigger < 40
            && Math.Abs((int)state.LeftThumbX) < 9000
            && Math.Abs((int)state.LeftThumbY) < 9000
            && Math.Abs((int)state.RightThumbX) < 9000
            && Math.Abs((int)state.RightThumbY) < 9000;
    }

    internal static string? DetectButton(ControllerState state)
    {
        if (!state.Connected)
        {
            return null;
        }

        (ushort Mask, string Name)[] buttons =
        [
            (0x0001, "DpadUp"),
            (0x0002, "DpadDown"),
            (0x0004, "DpadLeft"),
            (0x0008, "DpadRight"),
            (0x0010, "Start"),
            (0x0020, "Back"),
            (0x0040, "LeftThumb"),
            (0x0080, "RightThumb"),
            (0x0100, "LeftShoulder"),
            (0x0200, "RightShoulder"),
            (0x1000, "A"),
            (0x2000, "B"),
            (0x4000, "X"),
            (0x8000, "Y"),
        ];

        foreach (var button in buttons)
        {
            if ((state.Buttons & button.Mask) != 0)
            {
                return button.Name;
            }
        }

        if (state.LeftTrigger > 100) return "LeftTrigger";
        if (state.RightTrigger > 100) return "RightTrigger";
        if (state.LeftThumbY > 17000) return "LStickUp";
        if (state.LeftThumbY < -17000) return "LStickDown";
        if (state.LeftThumbX < -17000) return "LStickLeft";
        if (state.LeftThumbX > 17000) return "LStickRight";
        if (state.RightThumbY > 17000) return "RStickUp";
        if (state.RightThumbY < -17000) return "RStickDown";
        if (state.RightThumbX < -17000) return "RStickLeft";
        if (state.RightThumbX > 17000) return "RStickRight";
        return null;
    }

    internal static string? DetectAxis(ControllerState state)
    {
        if (!state.Connected)
        {
            return null;
        }

        var candidates = new (int Value, string Name)[]
        {
            (Math.Abs((int)state.LeftThumbX), "LeftThumbX Axis"),
            (Math.Abs((int)state.LeftThumbY), "LeftThumbY Axis"),
            (Math.Abs((int)state.RightThumbX), "RightThumbX Axis"),
            (Math.Abs((int)state.RightThumbY), "RightThumbY Axis"),
        };

        var best = candidates.MaxBy(candidate => candidate.Value);
        return best.Value > 15000 ? best.Name : null;
    }
}
