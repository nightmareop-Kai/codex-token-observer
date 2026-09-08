import Foundation

/// Commands share the collector's resource path, database, and environment.
/// Execution and pipe reads run off the main actor; Python owns all identity/network I/O.
struct CollectorCommand: Sendable {
    let resources: URL
    let database: URL
    let environment: [String: String]

    static func bundled() -> Self {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/counter")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Token Observer", isDirectory: true)
        return Self(resources: resources, database: support.appendingPathComponent("token_counter.sqlite3"),
                    environment: ProcessInfo.processInfo.environment.merging([
                        "PYTHONPATH": resources.appendingPathComponent("src").path,
                        "PYTHONUNBUFFERED": "1"
                    ]) { _, new in new })
    }

    func makeProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.currentDirectoryURL = resources
        process.environment = environment
        process.arguments = ["-m", "codex_token_counter.cli", "--db", database.path] + arguments
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return process
    }

    func run(arguments: [String]) async -> Data? {
        await Task.detached(priority: .utility) {
            let process = makeProcess(arguments: arguments)
            let output = Pipe()
            process.standardOutput = output
            do { try process.run() } catch { return nil }
            // Never let a failed helper leave the UI waiting indefinitely.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            // Error exits may still contain a sanitized, actionable profile response.
            guard !data.isEmpty, data.count <= 512_000 else { return nil }
            return data
        }.value
    }
}
