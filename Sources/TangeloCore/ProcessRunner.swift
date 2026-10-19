import Darwin
import Foundation

/// Runs command-line tools (ffmpeg, cwebp, ditto, zip, tar) with cancellation support.
///
/// Tools are started with `posix_spawn` rather than `Process`, which would give each one a process group of its own:
/// here they stay in the caller's group. The app starts its `tangelo-cli job` worker with `Process`, so the worker
/// leads a group, and every tool the worker starts is in it. If the worker dies abruptly (crash, SIGKILL, jetsam), the
/// app stops those tools by signalling that group (`WorkerSession` in Sources/Tangelo/JobRunner.swift); in groups of
/// their own they would be handed to launchd and keep converting for nobody.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    /// Runs `path` with `args`. `onStdoutLine` receives stdout lines as they arrive (used for ffmpeg progress).
    @discardableResult
    public static func run(_ path: String, _ args: [String], currentDirectory: URL? = nil,
                           ctx: JobContext? = nil,
                           onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let outPipe = Pipe(), errPipe = Pipe()
        let tool = try Tool(path, args, currentDirectory: currentDirectory,
                            stdout: outPipe.fileHandleForWriting.fileDescriptor,
                            stderr: errPipe.fileHandleForWriting.fileDescriptor)
        // The tool has its own copies; ours must close for the reads below to reach end of file.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let collector = OutputCollector(onLine: onStdoutLine)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { collector.appendOut(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { collector.appendErr(d) }
        }
        ctx?.onCancel { tool.signal(SIGTERM) }
        let status = await tool.exitStatus()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
        collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
        try ctx?.check()
        return Result(status: status, stdout: collector.out, stderr: collector.err)
    }

    /// Like `run`, but throws with the tool's last error line when it exits non-zero.
    @discardableResult
    public static func checked(_ path: String, _ args: [String], currentDirectory: URL? = nil, ctx: JobContext? = nil,
                               onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let r = try await run(path, args, currentDirectory: currentDirectory, ctx: ctx, onStdoutLine: onStdoutLine)
        guard r.status == 0 else {
            let tool = URL(fileURLWithPath: path).lastPathComponent
            let lines = r.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            throw TangeloError.failed("\(tool) failed: \(lines.last ?? "exit code \(r.status)")")
        }
        return r
    }

    /// Runs `path` to the end for callers that aren't async (cwebp, ditto) and returns its exit status. Its output is
    /// discarded, or with `inheritOutput` goes to this process's own stdout and stderr.
    public static func runAndWait(_ path: String, _ args: [String], inheritOutput: Bool = false) throws -> Int32 {
        let tool = try Tool(path, args, currentDirectory: nil,
                            stdout: inheritOutput ? STDOUT_FILENO : nil, stderr: inheritOutput ? STDERR_FILENO : nil)
        return tool.waitUntilExit()
    }
}

/// A tool started by `ProcessRunner`. It is reaped under `lock` and only signalled before that, so a signal can't
/// reach an unrelated process that was later given the same pid.
private final class Tool: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var reaped = false

    /// Starts `path` with stdin on /dev/null and stdout/stderr on the given descriptors (nil: /dev/null). As with
    /// `Process`, nothing else is inherited and signals start unblocked with default handling (a worker ignores
    /// SIGTERM, SIGINT and SIGPIPE; its tools mustn't). Unlike `Process`, the tool joins this process's group.
    init(_ path: String, _ args: [String], currentDirectory: URL?, stdout: Int32?, stderr: Int32?) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        for (fd, target) in [(stdout, STDOUT_FILENO), (stderr, STDERR_FILENO)] {
            if let fd, fd == target {
                posix_spawn_file_actions_addinherit_np(&actions, fd)
            } else if let fd {
                posix_spawn_file_actions_adddup2(&actions, fd, target)
            } else {
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_WRONLY, 0)
            }
        }
        if let currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard error == 0 else {
            throw TangeloError.failed("Couldn't start \(URL(fileURLWithPath: path).lastPathComponent): \(String(cString: strerror(error)))")
        }
        self.pid = pid
    }

    func signal(_ signal: Int32) {
        lock.withLock { if !reaped { _ = kill(pid, signal) } }
    }

    /// `waitUntilExit` on a thread of its own: tools can run for minutes.
    func exitStatus() async -> Int32 {
        await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            Thread.detachNewThread { c.resume(returning: self.waitUntilExit()) }
        }
    }

    /// Blocks until the tool ends, then reaps it. Returns its exit code, or the number of the signal that ended it
    /// (like `Process.terminationStatus`).
    func waitUntilExit() -> Int32 {
        var info = siginfo_t()
        // WNOWAIT leaves the tool unreaped until `lock` is held, so `signal` can't race the reaping.
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        return lock.withLock {
            reaped = true
            var status: Int32 = 0
            var r: pid_t
            repeat { r = waitpid(pid, &status, 0) } while r == -1 && errno == EINTR
            guard r == pid else { return -1 }
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : signal
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()
    private var lineBuffer = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ d: Data) {
        guard !d.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            outData.append(d)
            guard onLine != nil else { return }
            lineBuffer.append(d)
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer[lineBuffer.startIndex..<nl]
                lines.append(String(decoding: line, as: UTF8.self))
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            }
        }
        lines.forEach { onLine?($0) }
    }

    func appendErr(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.withLock {
            errData.append(d)
            // Keep memory bounded for chatty tools.
            if errData.count > 256_000 { errData = errData.suffix(64_000) }
        }
    }

    var out: String { lock.withLock { String(decoding: outData, as: UTF8.self) } }
    var err: String { lock.withLock { String(decoding: errData, as: UTF8.self) } }
}
