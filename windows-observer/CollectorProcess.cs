using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace TokenObserver;

public sealed class CollectorProcess : IDisposable
{
    private Process? process;
    private readonly CancellationTokenSource cancellation = new();
    public event Action<UsageSnapshot>? Snapshot;
    public event Action<string>? Unavailable;

    public static ProcessStartInfo Command(string database, string sessions, params string[] command)
    {
        var python = Path.Combine(AppContext.BaseDirectory, "python", "python.exe");
        if (!File.Exists(python)) throw new FileNotFoundException("Bundled Python is missing. Extract the complete ZIP before opening the app.");
        var start = new ProcessStartInfo(python)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = AppContext.BaseDirectory
        };
        // The embedded runtime's checked-in packaging configuration adds counter/src.
        start.ArgumentList.Add("-B");
        start.ArgumentList.Add("-u");
        start.ArgumentList.Add("-m");
        start.ArgumentList.Add("codex_token_counter.cli");
        start.ArgumentList.Add("--db"); start.ArgumentList.Add(database);
        start.ArgumentList.Add("--sessions"); start.ArgumentList.Add(sessions);
        foreach (var argument in command) start.ArgumentList.Add(argument);
        return start;
    }

    public void Start(string database, string sessions, bool readQuota = true)
    {
        if (process != null) return;
        try
        {
            var arguments = readQuota
                ? new[] { "stream", "--interval", "300", "--account-quota" }
                : new[] { "stream", "--interval", "300" };
            process = Process.Start(Command(database, sessions, arguments))
                ?? throw new IOException("Collector did not start.");
            _ = ReadAsync(process, cancellation.Token);
        }
        catch (Exception exception) when (exception is IOException || exception is System.ComponentModel.Win32Exception)
        {
            Unavailable?.Invoke("Unable to start the collector. Extract the full download and try again.");
        }
    }

    private async Task ReadAsync(Process child, CancellationToken token)
    {
        // Drain stderr without writing local session data or environment details to logs.
        var errors = child.StandardError.ReadToEndAsync(token);
        try
        {
            while (!token.IsCancellationRequested)
            {
                var line = await child.StandardOutput.ReadLineAsync(token);
                if (line == null) break;
                if (line.Length > 4 * 1024 * 1024) continue;
                try
                {
                    var snapshot = JsonSerializer.Deserialize<UsageSnapshot>(line);
                    if (snapshot != null) Snapshot?.Invoke(snapshot);
                }
                catch (JsonException) { /* Keep the next complete snapshot. */ }
            }
            if (!token.IsCancellationRequested)
                Unavailable?.Invoke("Collector stopped. Quit and reopen the app to retry.");
        }
        catch (OperationCanceledException) { }
        catch (IOException) { if (!token.IsCancellationRequested) Unavailable?.Invoke("Collector disconnected."); }
        finally { try { await errors; } catch (OperationCanceledException) { } catch (IOException) { } }
    }

    public void Dispose()
    {
        cancellation.Cancel();
        try
        {
            if (process != null && !process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
        }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
        process?.Dispose();
        process = null;
    }
}
