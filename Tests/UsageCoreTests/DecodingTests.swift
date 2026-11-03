import Foundation
import Testing
@testable import UsageCore

@Suite struct DecodingTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "usage", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func date(_ string: String) throws -> Date {
        try #require(ISO8601.parse(string))
    }

    @Test func decodesRealFixture() throws {
        let snapshot = try UsageSnapshot.decode(fixture())

        // Literals copied from Fixtures/usage.json at capture time.
        #expect(snapshot[.claude]?.session == UsageWindow(usedPercent: 25, resetsAt: try date("2026-11-03T09:59:00Z")))
        #expect(snapshot[.claude]?.weekly == UsageWindow(usedPercent: 69, resetsAt: try date("2026-11-04T07:59:00Z")))
        #expect(snapshot[.codex]?.session == UsageWindow(usedPercent: 55, resetsAt: try date("2026-11-03T09:16:55Z")))
        #expect(snapshot[.codex]?.weekly == UsageWindow(usedPercent: 9, resetsAt: try date("2026-11-10T04:16:55Z")))
    }

    @Test func malformedJSONThrowsTypedError() {
        #expect(throws: UsageDecodingError.self) { try UsageSnapshot.decode(Data("not json".utf8)) }
        #expect(throws: UsageDecodingError.self) { try UsageSnapshot.decode(Data(#"{"provider":"claude"}"#.utf8)) }
    }

    @Test func emptyArrayThrows() {
        #expect(throws: UsageDecodingError.noKnownProviders) { try UsageSnapshot.decode(Data("[]".utf8)) }
    }

    @Test func missingProviderIsAbsentNotZero() throws {
        let json = #"[{"provider":"codex","usage":{"primary":{"usedPercent":10,"resetsAt":"2026-11-03T09:16:55Z"},"secondary":{"usedPercent":2}}}]"#
        let snapshot = try UsageSnapshot.decode(Data(json.utf8))
        #expect(snapshot[.claude] == nil)
        #expect(snapshot[.codex]?.weekly == UsageWindow(usedPercent: 2, resetsAt: nil))
    }

    @Test func missingWindowsAreNil() throws {
        let json = #"[{"provider":"claude","usage":{"primary":null}},{"provider":"codex"}]"#
        let snapshot = try UsageSnapshot.decode(Data(json.utf8))
        #expect(snapshot[.claude] == ProviderUsage(session: nil, weekly: nil))
        #expect(snapshot[.codex] == ProviderUsage(session: nil, weekly: nil))
    }

    @Test func fractionalPercentDecodesAndClamps() throws {
        let json = #"[{"provider":"claude","usage":{"primary":{"usedPercent":14.6},"secondary":{"usedPercent":130}}}]"#
        let snapshot = try UsageSnapshot.decode(Data(json.utf8))
        #expect(snapshot[.claude]?.session?.usedPercent == 14.6)
        #expect(snapshot[.claude]?.weekly?.usedPercent == 100)
    }

    /// Shape captured from `codexbar usage --provider claude --source oauth` (exit 3, stdout).
    private let claudeError = Data(#"[{"source":"oauth","error":{"message":"Claude OAuth token missing scope.","kind":"provider","code":3},"provider":"claude"}]"#.utf8)

    @Test func errorEntriesAreSkippedAndTheirMessageIsReadable() throws {
        #expect(throws: UsageDecodingError.noKnownProviders) { try UsageSnapshot.decode(claudeError) }
        #expect(UsageSnapshot.errorMessage(in: claudeError, for: .claude) == "Claude OAuth token missing scope.")
        #expect(UsageSnapshot.errorMessage(in: claudeError, for: .codex) == nil)
    }

    @Test func fetcherTurnsErrorsAndEmptyAnswersIntoErrors() throws {
        #expect(throws: UsageDecodingError.providerError(.claude, "Claude OAuth token missing scope.")) {
            try CodexBarFetcher.usage(for: .claude, from: claudeError)
        }
        #expect(throws: UsageDecodingError.noWindows(.claude)) {
            try CodexBarFetcher.usage(for: .claude, from: Data(#"[{"provider":"claude"}]"#.utf8))
        }
        #expect(throws: UsageDecodingError.missingProvider(.codex)) {
            try CodexBarFetcher.usage(for: .codex, from: Data(#"[{"provider":"claude","usage":{"primary":{"usedPercent":1}}}]"#.utf8))
        }
        let usage = try CodexBarFetcher.usage(for: .claude, from: fixture())
        #expect(usage.weekly?.usedPercent == 69)
    }

    @Test func executableFallsBackThroughCandidates() {
        let intel = CodexBarFetcher.resolveExecutable { $0 == "/usr/local/bin/codexbar" }
        #expect(intel?.path == "/usr/local/bin/codexbar")
        let bundled = CodexBarFetcher.resolveExecutable { $0.hasSuffix("CodexBarCLI") }
        #expect(bundled?.path == "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")
        #expect(CodexBarFetcher.resolveExecutable { _ in false } == nil)
    }

    @Test func unknownProvidersAreIgnored() throws {
        let json = #"[{"provider":"cursor","usage":{"primary":{"usedPercent":5}}}]"#
        #expect(throws: UsageDecodingError.noKnownProviders) { try UsageSnapshot.decode(Data(json.utf8)) }
    }
}
