import AppKit
import OSLog
import TangeloCore

/// Unified-log channel: `log stream --predicate 'subsystem == "app.tangelo.mac"'`
let jobLog = Logger(subsystem: "app.tangelo.mac", category: "jobs")

/// Runs actions in the background and reports through a HUD.
@MainActor
final class JobRunner {
    static let shared = JobRunner()
    /// Jobs still running (used by the memory test and to release memory when everything is idle).
    private(set) var activeJobs = 0

    /// Resolves the dropped items (receiving promised files if needed). With a job context, cancelling the job ends the
    /// wait: promised files can take minutes (Photos fetching from iCloud) or never come, and `PromiseLoader.wait`
    /// doesn't react to task cancellation, so the HUD's ✕ would otherwise do nothing until they arrive.
    func resolve(_ source: DropSource, ctx: JobContext? = nil) async throws -> [InputItem] {
        switch source {
        case .files(let items):
            return items
        case .promises(let loader, _):
            guard let ctx else { return try await loader.wait().map { InputItem(url: $0) } }
            let once = ResumeOnce<[URL]>()
            let urls = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[URL], Error>) in
                once.set(c)
                ctx.onCancel { once.resume(with: .failure(TangeloError.cancelled)) }
                Task { @MainActor in
                    do { once.resume(with: .success(try await loader.wait())) } catch { once.resume(with: .failure(error)) }
                }
            }
            return urls.map { InputItem(url: $0) }
        }
    }

    /// Runs a catalog action (quick actions only; tools are opened by ToolPresenter).
    /// The conversion runs in a `tangelo-cli job` helper process when one is available, so the codecs and models
    /// it loads go away with the helper instead of staying resident in the menu-bar app.
    func run(_ action: Action, source: DropSource, near point: NSPoint) {
        let count: Int
        switch source {
        case .files(let items): count = items.count
        case .promises(_, let items): count = items.count
        }
        let model = HUDModel(title: action.verb, subtitle: count > 1 ? "0 of \(count) saved" : "Working…")
        jobLog.info("run \(action.id, privacy: .public) on \(count) item(s)")
        let id = action.id
        start(model: model, near: point) { ctx in
            let items = try await self.resolve(source, ctx: ctx)
            if let worker = JobWorker.executable() {
                do {
                    return try await JobWorker.run(worker, action: id, items: items, ctx: ctx)
                } catch let unusable as JobWorker.Unavailable {
                    jobLog.error("worker unusable (\(unusable.reason, privacy: .public)); running \(id, privacy: .public) in-process")
                    try ctx.check()
                }
            } else {
                jobLog.info("no tangelo-cli worker found; running \(id, privacy: .public) in-process")
            }
            return try await Runner.run(id, items: items, ctx: ctx)
        }
    }

    /// Runs custom work (used by the tool windows) with the same HUD and finishing behavior.
    func run(title: String, near point: NSPoint, work: @escaping @Sendable (JobContext) async throws -> Void) {
        let model = HUDModel(title: title, subtitle: "Working…")
        jobLog.info("run tool job \(title, privacy: .public)")
        start(model: model, near: point) { ctx in
            try await work(ctx)
            var r = RunResult()
            r.outputs = ctx.outputs
            r.summary = ctx.summary
            return r
        }
    }

    private func start(model: HUDModel, near point: NSPoint, body: @escaping @Sendable (JobContext) async throws -> RunResult) {
        activeJobs += 1
        let hud = HUDManager.shared.present(model, near: point)
        let ctx = JobContext(settings: AppSettings.shared.engine)
        ctx.progressHandler = { [weak model] fraction, detail in
            DispatchQueue.main.async {
                guard let model, model.phase == .running else { return }
                if let fraction { model.progress = fraction }
                if let detail { model.subtitle = detail }
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            do {
                let result = try await body(ctx)
                await MainActor.run { self.finish(hud: hud, model: model, result: result) }
            } catch {
                await MainActor.run { self.fail(hud: hud, error: error) }
            }
        }
        model.onCancel = {
            ctx.cancel()
            task.cancel()
        }
    }

    private func jobEnded() {
        activeJobs = max(0, activeJobs - 1)
        if activeJobs == 0 { MemoryRelief.afterWork() }
    }

    private func finish(hud: HUDController, model: HUDModel, result: RunResult) {
        defer { jobEnded() }
        jobLog.info("done: \(result.outputs.count) output(s), \(result.failures.count) failure(s) \(result.summary ?? "", privacy: .public)")
        for f in result.failures { jobLog.error("item failed: \(f.message, privacy: .public)") }
        let settings = AppSettings.shared
        if let text = result.clipboardText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let outputs = result.outputs
        settings.addRecent(outputs)
        if settings.revealInFinder && !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }

        var title = "Saved"
        var subtitle: String
        if let text = result.clipboardText {
            title = "Copied to clipboard"
            let words = text.split { $0.isWhitespace || $0.isNewline }.count
            subtitle = "\(words) word\(words == 1 ? "" : "s") of text"
        } else if outputs.isEmpty, let summary = result.summary {
            title = model.title.replacingOccurrences(of: "Counting words", with: "Word count")
            subtitle = summary
        } else if outputs.count == 1 {
            subtitle = outputs[0].lastPathComponent + (result.summary.map { " · \($0)" } ?? "")
        } else {
            subtitle = "\(outputs.count) of \(outputs.count + result.failures.count) saved" + (result.summary.map { " · \($0)" } ?? "")
        }
        if !result.failures.isEmpty {
            subtitle += "\n\(result.failures.count) failed: \(result.failures[0].message)"
        }
        if settings.playSound { NSSound(named: "Pop")?.play() }
        hud.finish(phase: .done, title: title, subtitle: subtitle, outputs: outputs)
    }

    private func fail(hud: HUDController, error: Error) {
        defer { jobEnded() }
        jobLog.error("job failed: \(error.localizedDescription, privacy: .public)")
        if case TangeloError.cancelled = error {
            hud.finish(phase: .failed, title: "Cancelled", subtitle: "Nothing was saved.", outputs: [])
            return
        }
        let message = error.localizedDescription
        let gentle = message.contains("already as small") || message.contains("already has selectable text")
        hud.finish(phase: gentle ? .done : .failed, title: gentle ? "Nothing to do" : "Couldn't finish", subtitle: message, outputs: [])
        if AppSettings.shared.playSound && !gentle { NSSound(named: "Basso")?.play() }
    }
}

/// A continuation resumed by whichever of several racing callers comes first; later calls do nothing.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.withLock { continuation = c }
    }

    func resume(with result: Result<T, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}

// MARK: - Worker process

/// Runs one catalog action in a short-lived `tangelo-cli job` process (protocol: Sources/TangeloCLI/Worker.swift).
/// The request goes in on stdin; JSON progress lines and one final result or error line come back on stdout.
/// Progress and cancellation go through the job's `JobContext`, so the HUD, its ✕ button and the finish/fail
/// paths behave exactly as they do for in-process jobs.
enum JobWorker {
    /// The helper couldn't do the job (missing, didn't start, or wrote something other than the protocol).
    /// The caller runs the action in-process instead. (A helper that crashes fails the job instead: see `outcome()`.)
    struct Unavailable: Error {
        let reason: String
    }

    /// `tangelo-cli` in Contents/Helpers (own bundle identity, so it never registers as a second "Tangelo"),
    /// else next to the app's executable (development builds).
    /// Set TANGELO_NO_WORKER=1 in the environment to keep every job in-process.
    static func executable() -> URL? {
        if ProcessInfo.processInfo.environment["TANGELO_NO_WORKER"] != nil { return nil }
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tangelo-cli"),
                          Bundle.main.url(forAuxiliaryExecutable: "tangelo-cli"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("tangelo-cli")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ executable: URL, action: String, items: [InputItem], ctx: JobContext) async throws -> RunResult {
        try ctx.check()
        let s = ctx.settings
        let request: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            request = try encoder.encode(WorkerRequest(
                action: action, files: items.map(\.url.path),
                settings: .init(quality: s.quality, pdfDPI: s.pdfDPI, keepLocation: s.keepLocation,
                                outputFolder: s.outputFolder?.path, ffmpegPath: s.ffmpegPath, cwebpPath: s.cwebpPath)))
        } catch {
            throw Unavailable(reason: "couldn't encode the request: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["job"]
        process.qualityOfService = .userInitiated
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let session = WorkerSession(process: process, ctx: ctx)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                session.outputEnded()
            } else {
                session.received(data)
            }
        }
        let logLines = LineBuffer(limit: 16_384)
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            for line in data.isEmpty ? logLines.flush() : logLines.append(data) {
                jobLog.info("worker: \(String(decoding: line, as: UTF8.self), privacy: .public)")
            }
        }
        process.terminationHandler = { _ in session.processEnded() }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw Unavailable(reason: "couldn't start \(executable.path): \(error.localizedDescription)")
        }
        jobLog.info("worker \(process.processIdentifier) running \(action, privacy: .public)")
        ctx.onCancel { [weak session] in session?.stop() }

        // A worker that dies before reading its request must not take the app down with SIGPIPE.
        let requestPipe = input.fileHandleForWriting
        _ = fcntl(requestPipe.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try requestPipe.write(contentsOf: request)
        } catch {
            let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error ?? error
            jobLog.error("couldn't send the request to the worker: \(cause.localizedDescription, privacy: .public)")
        }
        try? requestPipe.close()

        await session.ended()
        process.terminationHandler = nil
        output.fileHandleForReading.readabilityHandler = nil
        return try session.outcome()
    }
}

/// Follows one worker run: splits stdout into lines, forwards progress to the job context, keeps the final line,
/// and ends once stdout has closed and the process has exited.
private final class WorkerSession: @unchecked Sendable {
    private enum Final {
        case result(RunResult)
        case failure(String, cancelled: Bool)
    }

    private let process: Process
    private let ctx: JobContext
    private let lines = LineBuffer()
    private let decoder = JSONDecoder() // only used on the stdout handler's (serial) queue
    private let lock = NSLock()
    private var final: Final?
    private var junk: String?
    private var outputDone = false
    private var exited = false
    private var over = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(process: Process, ctx: JobContext) {
        self.process = process
        self.ctx = ctx
    }

    /// stdout data, in order.
    func received(_ data: Data) {
        for line in lines.append(data) { handle(line) }
    }

    /// stdout reached end of file.
    func outputEnded() {
        for line in lines.flush() { handle(line) }
        let running = lock.withLock { () -> Bool in
            outputDone = true
            return !exited
        }
        // The worker closes stdout by exiting; make sure it really goes.
        if running { killIfStillRunning(after: 5) }
        endIfDone()
    }

    func processEnded() {
        stopLeftoverTools()
        let awaitingOutput = lock.withLock { () -> Bool in
            exited = true
            return !outputDone
        }
        if awaitingOutput {
            // stdout normally closes with the process; if something else still holds it open, don't wait forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.endIfDone(force: true) }
        }
        endIfDone()
    }

    /// SIGTERM lets the worker stop cleanly (it reports "Cancelled"); SIGKILL follows if it lingers.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        killIfStillRunning(after: 5)
    }

    func ended() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done = lock.withLock { () -> Bool in
                if over { return true }
                waiter = c
                return false
            }
            if done { c.resume() }
        }
    }

    /// What the run produced. Missing, crashed or garbled workers throw `JobWorker.Unavailable`.
    func outcome() throws -> RunResult {
        if process.isRunning { // can't happen once ended; never ask a running Process for its status
            stop()
            throw JobWorker.Unavailable(reason: "worker still running after its output ended")
        }
        let (final, junk) = lock.withLock { (self.final, self.junk) }
        let status = process.terminationStatus
        let reason = process.terminationReason
        let how = reason == .uncaughtSignal ? "signal \(status)" : "exit status \(status)"
        switch final {
        case .result(let result)?:
            if reason != .exit || status != 0 {
                jobLog.error("worker reported its result, then ended with \(how, privacy: .public)")
            }
            return result
        case .failure(let message, let cancelled)?:
            if cancelled || ctx.isCancelled { throw TangeloError.cancelled }
            throw TangeloError.failed(message)
        case nil:
            if ctx.isCancelled { throw TangeloError.cancelled }
            // Checked before the signal: a helper that doesn't speak the protocol is sent SIGTERM by `reject`, so a
            // signal here is ours, not a crash, and the job still runs in-process.
            if let junk { throw JobWorker.Unavailable(reason: "unexpected output “\(junk)” (\(how))") }
            if reason == .uncaughtSignal {
                // Re-running in-process could take the whole app down with it.
                jobLog.error("worker crashed (\(how, privacy: .public))")
                throw TangeloError.failed("The converter stopped unexpectedly while working on this file.")
            }
            throw JobWorker.Unavailable(reason: "ended with \(how) before reporting a result")
        }
    }

    private func handle(_ line: Data) {
        guard line.contains(where: { $0 > 0x20 }) else { return } // blank
        guard let message = try? decoder.decode(WorkerMessage.self, from: line) else { return reject(line) }
        guard lock.withLock({ final == nil && junk == nil }) else { return } // nothing counts after the final line
        if let body = message.result {
            lock.withLock { final = .result(body.runResult) }
        } else if let error = message.error {
            lock.withLock { final = .failure(error, cancelled: message.cancelled ?? false) }
        } else if message.progress != nil || message.detail != nil {
            ctx.report(message.progress, message.detail)
        }
    }

    /// Not the protocol (e.g. an older tangelo-cli printing its usage): stop it; the job then runs in-process.
    private func reject(_ line: Data) {
        let first = lock.withLock { () -> Bool in
            guard final == nil, junk == nil else { return false }
            junk = String(decoding: line.prefix(120), as: UTF8.self)
            return true
        }
        if first { stop() }
    }

    /// The tools the worker runs (ffmpeg, zip...) share its process group (see ProcessRunner; `Process` starts the worker
    /// as the leader of a new group) and normally end before it does. A worker that dies abruptly (crash, SIGKILL,
    /// jetsam) leaves them converting for nobody, so whatever is left of the group is stopped: SIGTERM, then SIGKILL.
    /// The group is named after the worker's pid, which isn't reused while the group has members; once it's empty,
    /// this finds nothing.
    private func stopLeftoverTools() {
        let group = process.processIdentifier
        guard group > 1, killpg(group, SIGTERM) == 0 else { return }
        jobLog.error("worker \(group) ended with tools still running; stopping them")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { _ = killpg(group, SIGKILL) }
    }

    private func killIfStillRunning(after seconds: Double) {
        let pid = process.processIdentifier
        // Weak: a finished job's Process (and its pipes' file descriptors) shouldn't wait out the timer.
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak process] in
            if let process, process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func endIfDone(force: Bool = false) {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !over, force || (outputDone && exited) else { return nil }
            over = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }
}

private struct WorkerRequest: Encodable {
    struct Settings: Encodable {
        var quality: Double
        var pdfDPI: Double
        var keepLocation: Bool
        var outputFolder: String?
        var ffmpegPath: String?
        var cwebpPath: String?
    }
    var action: String
    var files: [String]
    var settings: Settings
}

private struct WorkerMessage: Decodable {
    struct Failure: Decodable {
        var name: String
        var message: String
    }
    struct Body: Decodable {
        var outputs: [String]?
        var summary: String?
        var clipboard: String?
        var failures: [Failure]?

        var runResult: RunResult {
            var r = RunResult()
            r.outputs = (outputs ?? []).map { URL(fileURLWithPath: $0) }
            r.summary = summary
            r.clipboardText = clipboard
            r.failures = (failures ?? []).map { (name: $0.name, message: $0.message) }
            return r
        }
    }
    var progress: Double?
    var detail: String?
    var result: Body?
    var error: String?
    var cancelled: Bool?
}

/// Splits a byte stream into lines at "\n" only (a raw 0x0A never occurs inside a JSON string) and keeps partial
/// lines across reads. With a limit, an over-long line is passed on in pieces instead of growing without bound.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int?
    private var pending = Data()

    init(limit: Int? = nil) {
        self.limit = limit
    }

    func append(_ data: Data) -> [Data] {
        lock.withLock {
            var lines: [Data] = []
            var rest = data[...]
            while let nl = rest.firstIndex(of: 0x0A) {
                pending.append(contentsOf: rest[..<nl])
                lines.append(pending)
                pending = Data()
                rest = rest[rest.index(after: nl)...]
            }
            pending.append(contentsOf: rest)
            if let limit, pending.count > limit {
                lines.append(pending)
                pending = Data()
            }
            return lines
        }
    }

    func flush() -> [Data] {
        lock.withLock {
            defer { pending = Data() }
            return pending.isEmpty ? [] : [pending]
        }
    }
}
