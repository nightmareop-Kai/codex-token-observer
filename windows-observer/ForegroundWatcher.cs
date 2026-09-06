using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace TokenObserver;

public sealed class ForegroundWatcher : IDisposable
{
    private readonly Action<bool> changed;
    private readonly WinEventDelegate callback;
    private IntPtr hook;
    private bool last;
    public ForegroundWatcher(Action<bool> changed)
    {
        this.changed = changed;
        callback = (_, _, window, _, _, _, _) => Inspect(window);
        hook = SetWinEventHook(3, 3, IntPtr.Zero, callback, 0, 0, 0);
        Inspect(GetForegroundWindow());
    }
    public static bool IsTarget(string name) =>
        string.Equals(name, "Codex", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(name, "ChatGPT", StringComparison.OrdinalIgnoreCase);
    private void Inspect(IntPtr window)
    {
        GetWindowThreadProcessId(window, out var processId);
        if (processId == Environment.ProcessId) return;
        bool target = false;
        try { using var process = Process.GetProcessById((int)processId); target = IsTarget(process.ProcessName); }
        catch (ArgumentException) { }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
        last = target;
        changed(last);
    }
    public void Dispose() { if (hook != IntPtr.Zero) UnhookWinEvent(hook); hook = IntPtr.Zero; }
    private delegate void WinEventDelegate(IntPtr hook, uint eventType, IntPtr hwnd, int objectId, int childId, uint thread, uint time);
    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventDelegate callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint id);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
