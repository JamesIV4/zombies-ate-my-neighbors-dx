using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace ZamndxLauncher;

internal static class WindowTools
{
    private const int SwHide = 0;
    private const int SwShow = 5;
    private delegate bool EnumWindowsProc(nint window, nint parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, nint parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint window, out uint processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(nint window, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(nint window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BringWindowToTop(nint window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    private static extern nint SetActiveWindow(nint window);

    [DllImport("user32.dll")]
    private static extern nint SetFocus(nint window);

    internal static bool IsLuaConsoleTitle(string title) =>
        title.Equals("Lua Console", StringComparison.OrdinalIgnoreCase);

    internal static async Task CoordinateGameStartupAsync(
        Process process,
        TimeSpan maximumDuration,
        CancellationToken cancellationToken = default)
    {
        var deadline = DateTime.UtcNow + maximumDuration;
        DateTime? readySince = null;
        while (!process.HasExited && DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var luaConsoleFound = HideLuaConsoles(process.Id);

            var gameWindow = FindGameWindow(process.Id);
            if (gameWindow != nint.Zero)
            {
                FocusWindow(gameWindow);
            }

            if (luaConsoleFound && gameWindow != nint.Zero)
            {
                readySince ??= DateTime.UtcNow;
                if (DateTime.UtcNow - readySince >= TimeSpan.FromSeconds(3))
                {
                    return;
                }
            }
            else
            {
                readySince = null;
            }

            await Task.Delay(50, cancellationToken);
        }
    }

    internal static bool HideLuaConsoles(int processId)
    {
        var found = false;
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out var owner);
            if (owner == processId && IsLuaConsoleTitle(GetTitle(window)))
            {
                ShowWindow(window, SwHide);
                found = true;
            }
            return true;
        }, 0);
        return found;
    }

    private static nint FindGameWindow(int processId)
    {
        var result = nint.Zero;
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out var owner);
            if (owner != processId || !IsWindowVisible(window))
            {
                return true;
            }

            var title = GetTitle(window);
            if (string.IsNullOrWhiteSpace(title) || IsLuaConsoleTitle(title))
            {
                return true;
            }

            result = window;
            return false;
        }, 0);
        return result;
    }

    private static void FocusWindow(nint window)
    {
        ShowWindow(window, SwShow);

        var currentThread = GetCurrentThreadId();
        var targetThread = GetWindowThreadProcessId(window, out _);
        var foreground = GetForegroundWindow();
        var foregroundThread = foreground == nint.Zero
            ? 0
            : GetWindowThreadProcessId(foreground, out _);

        var attachedTarget = targetThread != 0
            && targetThread != currentThread
            && AttachThreadInput(currentThread, targetThread, true);
        var attachedForeground = foregroundThread != 0
            && foregroundThread != currentThread
            && foregroundThread != targetThread
            && AttachThreadInput(currentThread, foregroundThread, true);
        try
        {
            BringWindowToTop(window);
            SetForegroundWindow(window);
            SetActiveWindow(window);
            SetFocus(window);
        }
        finally
        {
            if (attachedForeground)
            {
                AttachThreadInput(currentThread, foregroundThread, false);
            }
            if (attachedTarget)
            {
                AttachThreadInput(currentThread, targetThread, false);
            }
        }
    }

    private static string GetTitle(nint window)
    {
        var text = new StringBuilder(1024);
        GetWindowText(window, text, text.Capacity);
        return text.ToString();
    }
}
