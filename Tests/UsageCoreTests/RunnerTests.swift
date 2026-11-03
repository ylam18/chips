import Foundation
import Testing
@testable import UsageCore

@Suite struct RunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func sh(_ script: String, timeout: TimeInterval = 10) async throws -> Data {
        try await CLIRunner().run(executable: shell, arguments: ["-c", script], environment: [:], timeout: timeout)
    }

    @Test func returnsStdout() async throws {
        #expect(try await sh("printf hello") == Data("hello".utf8))
    }

    @Test func nonZeroExitCarriesStderr() async {
        await #expect(throws: CLIError.failed(exitCode: 3, stderr: "boom", stdout: Data("out\n".utf8))) {
            try await sh("echo out; echo boom >&2; exit 3")
        }
    }

    @Test func failureMessageFallsBackToStdout() {
        let error = CLIError.failed(exitCode: 3, stderr: "", stdout: Data(#"{"error":"nope"}"#.utf8))
        #expect(error.errorDescription == #"CodexBar CLI exited with code 3: {"error":"nope"}"#)
    }

    @Test func timeoutKillsChildProcessesToo() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        await #expect(throws: CLIError.timedOut(seconds: 0.5)) {
            try await sh("sleep 30 & echo $! > '\(pidFile.path)'; wait", timeout: 0.5)
        }
        let childPID = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // kill(pid, 0) fails with ESRCH once the process is gone.
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
    }

    @Test func childHoldingPipesDoesNotBlockSuccess() async throws {
        let started = Date()
        let data = try await sh("(sleep 4 &); printf ok", timeout: 10)
        #expect(data == Data("ok".utf8))
        // Exit + drain grace, not the child's 4 s.
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func missingExecutableIsNotFound() async {
        await #expect(throws: CLIError.notFound(path: "/nonexistent/codexbar")) {
            try await CLIRunner().run(executable: URL(fileURLWithPath: "/nonexistent/codexbar"),
                                      arguments: [], environment: [:], timeout: 1)
        }
    }

    @Test func timeoutTerminatesProcess() async {
        let started = Date()
        await #expect(throws: CLIError.timedOut(seconds: 0.5)) {
            try await sh("exec sleep 30", timeout: 0.5)
        }
        // Timeout plus the kill grace period, well short of the 30 s sleep.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func ignoresSIGTERMThenGetsKilled() async {
        let started = Date()
        await #expect(throws: CLIError.timedOut(seconds: 0.5)) {
            try await sh("trap '' TERM; sleep 30 & wait; sleep 30", timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let data = try await sh("head -c 1000000 /dev/zero", timeout: 10)
        #expect(data.count == 1_000_000)
    }

    @Test func cancellationStopsRun() async {
        let started = Date()
        let task = Task { try await sh("exec sleep 30") }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func pathIsSetForFinderLaunches() {
        let environment = CodexBarFetcher.environment(base: ["PATH": "/usr/bin:/bin", "KEEP": "1"], home: "/Users/test")
        #expect(environment["PATH"] == "/opt/homebrew/bin:/Users/test/.local/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(environment["KEEP"] == "1")
    }
}
