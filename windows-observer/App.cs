using System;
using System.IO;
using System.Globalization;
using System.Threading;
using System.Windows;

namespace TokenObserver;

public static class App
{
    [STAThread]
    public static int Main(string[] args)
    {
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.GetCultureInfo("en-US");
        CultureInfo.DefaultThreadCurrentUICulture = CultureInfo.GetCultureInfo("en-US");
        var application = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        if (args.Length == 2 && args[0] == "--smoke-test")
            return SmokeTest.Run(application, Path.GetFullPath(args[1]));
        using var mutex = new Mutex(true, @"Local\CodexTokenObserver-v1", out var firstInstance);
        using var reopen = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\CodexTokenObserver-Show-v1");
        if (!firstInstance) { reopen.Set(); return 0; }
        var window = new ObserverWindow();
        var registration = ThreadPool.RegisterWaitForSingleObject(reopen, (_, _) =>
            window.Dispatcher.BeginInvoke(new Action(window.ShowObserver)), null, Timeout.Infinite, false);
        try { return application.Run(window); }
        finally { registration.Unregister(null); mutex.ReleaseMutex(); }
    }
}
