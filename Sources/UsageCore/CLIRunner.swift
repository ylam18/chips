import Darwin
import Foundation

public enum CLIError: Error, Equatable, LocalizedError {
    case notFound(path: String)
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)
    /// `stdout` is kept whole: CodexBar reports provider errors as JSON there.
    case failed(exitCode: Int32, stderr: String, stdout: Data)

    public var errorDescription: String? {
        switch self {
        case .notFound: "CodexBar CLI not found — install CodexBar"
        case .launchFailed(let detail): "Couldn't start CodexBar CLI: \(detail)"
        case .timedOut(let seconds): "CodexBar CLI timed out after \(Int(seconds))s"
        case .failed(let code, let stderr, let stdout):
            Self.describeFailure(code: code, detail: stderr.isEmpty ? String(decoding: stdout, as: UTF8.self) : stderr)
        }
    }

    private static func describeFailure(code: Int32, detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "CodexBar CLI exited with code \(code)" }
        return "CodexBar CLI exited with code \(code): \(trimmed.prefix(CLIRunner.messageLimit))"
    }
}

/// Runs one external program and returns its stdout. Output is drained as it arrives, so large
/// output cannot fill the pipe. On timeout or cancellation the program and every process it
/// spawned are terminated, then killed after a grace period.
public struct CLIRunner: Sendable {
    /// Between SIGTERM and SIGKILL when a run times out or is cancelled.
    static let killGrace: TimeInterval = 2
    /// After the program exits, how long to wait for its pipes to close. A child it left running
    /// can hold them open; the run completes with what was read once this passes.
    static let drainGrace: TimeInterval = 1
    static let messageLimit = 300

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CLIError.notFound(path: executable.path)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let run = RunState(process: process)
        process.standardOutput = run.stdout
        process.standardError = run.stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard run.setContinuation(continuation) else { return }
                run.startReading()
                process.terminationHandler = { finished in
                    run.exited(code: finished.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    run.finish(.failure(CLIError.launchFailed(error.localizedDescription)))
                    return
                }

                // Cancelled while launching: the stop request found no process to signal.
                if run.isStopRequested { run.signalTree(SIGTERM) }
                run.scheduleTimeout(after: timeout)
            }
        } onCancel: {
            run.stop(reason: CancellationError())
        }
    }
}

/// Shared between the pipe handlers, the termination handler, the timeout and cancellation.
/// Every mutable field is guarded by `lock`; the continuation is resumed exactly once, and
/// resuming stops the pipe handlers and cancels the timeout.
private final class RunState: @unchecked Sendable {
    let stdout = Pipe()
    let stderr = Pipe()
    private let process: Process
    private let lock = NSLock()
    private var output = Data()
    private var errorOutput = Data()
    private var openPipes = 2
    private var exitCode: Int32?
    private var continuation: CheckedContinuation<Data, Error>?
    private var stopReason: Error?
    private var timeoutItem: DispatchWorkItem?
    private var resumed = false

    init(process: Process) {
        self.process = process
    }

    /// Returns `false` when the run was cancelled before it started; the caller must not launch.
    func setContinuation(_ continuation: CheckedContinuation<Data, Error>) -> Bool {
        lock.withLock {
            self.continuation = continuation
            guard let stopReason else { return true }
            resumeLocked(.failure(stopReason))
            return false
        }
    }

    var isStopRequested: Bool {
        lock.withLock { stopReason != nil }
    }

    func startReading() {
        for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                lock.withLock {
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        openPipes -= 1
                        if exitCode != nil, openPipes == 0 { completeLocked() }
                    } else if isStdout {
                        output.append(data)
                    } else {
                        errorOutput.append(data)
                    }
                }
            }
        }
    }

    func exited(code: Int32) {
        lock.withLock {
            exitCode = code
            if openPipes == 0 { completeLocked() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + CLIRunner.drainGrace) { [self] in
            lock.withLock { completeLocked() }
        }
    }

    func scheduleTimeout(after timeout: TimeInterval) {
        let item = DispatchWorkItem { [self] in
            stop(reason: CLIError.timedOut(seconds: timeout))
        }
        let scheduled: Bool = lock.withLock {
            guard !resumed else { return false }
            timeoutItem = item
            return true
        }
        if scheduled { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item) }
    }

    func finish(_ result: Result<Data, Error>) {
        lock.withLock { resumeLocked(result) }
    }

    /// Terminates the process tree, escalating to SIGKILL after the grace period. A program that
    /// already exited is left alone: its result is about to be delivered.
    func stop(reason: Error) {
        let shouldSignal: Bool = lock.withLock {
            guard !resumed, stopReason == nil, exitCode == nil else { return false }
            stopReason = reason
            return continuation != nil
        }
        guard shouldSignal else { return }

        signalTree(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + CLIRunner.killGrace) { [self] in
            signalTree(SIGKILL)
            finish(.failure(reason))
        }
    }

    /// Signals the program's descendants (deepest first) and then the program itself, so a child
    /// such as the `claude` CLI is not orphaned holding the pipes.
    func signalTree(_ signal: Int32) {
        guard process.isRunning else { return }
        let root = process.processIdentifier
        for pid in Self.descendants(of: root).reversed() { kill(pid, signal) }
        kill(root, signal)
    }

    private static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [root]
        while let parent = queue.popLast() {
            let estimate = proc_listchildpids(parent, nil, 0)
            guard estimate > 0 else { continue }
            var buffer = [pid_t](repeating: 0, count: Int(estimate) + 8)
            let count = buffer.withUnsafeMutableBytes { raw in
                proc_listchildpids(parent, raw.baseAddress, Int32(raw.count))
            }
            let children = buffer.prefix(max(Int(count), 0)).filter { $0 > 0 }
            found.append(contentsOf: children)
            queue.append(contentsOf: children)
        }
        return found
    }

    /// Resolves from the collected output once the program has exited.
    private func completeLocked() {
        guard let exitCode else { return }
        if let stopReason {
            resumeLocked(.failure(stopReason))
        } else if exitCode == 0 {
            resumeLocked(.success(output))
        } else {
            let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            resumeLocked(.failure(CLIError.failed(exitCode: exitCode, stderr: message, stdout: output)))
        }
    }

    private func resumeLocked(_ result: Result<Data, Error>) {
        guard !resumed, let continuation else { return }
        resumed = true
        self.continuation = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        // Stop reading but don't close: a handler may be mid-read on another thread, and reading a
        // closed handle raises. The pipes close when this state is released.
        for pipe in [stdout, stderr] {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        continuation.resume(with: result)
    }
}
