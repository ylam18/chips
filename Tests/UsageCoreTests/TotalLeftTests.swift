import Foundation
import Testing
@testable import UsageCore

@Suite struct TotalLeftTests {
    private func window(_ percent: Double) -> UsageWindow { UsageWindow(usedPercent: percent, resetsAt: nil) }

    @Test func leftIsTheRemainderOfUsed() {
        #expect(window(56).leftPercent == 44)
        #expect(window(100).leftPercent == 0)
        #expect(window(0).leftPercent == 100)
    }

    @Test func totalLeftAveragesAllFourWindows() {
        let snapshot = UsageSnapshot(providers: [
            .claude: ProviderUsage(session: window(56), weekly: window(72)), // 44%, 28% left
            .codex: ProviderUsage(session: window(100), weekly: window(16)), // 0%, 84% left
        ])
        #expect(abs((snapshot.totalLeft ?? -1) - 0.39) < 1e-9)
    }

    @Test func missingWindowsAreLeftOutOfTheAverage() {
        let snapshot = UsageSnapshot(providers: [
            .claude: ProviderUsage(session: nil, weekly: nil),
            .codex: ProviderUsage(session: window(25), weekly: nil),
        ])
        #expect(snapshot.totalLeft == 0.75)
    }

    @Test func noDataIsNil() {
        #expect(UsageSnapshot(providers: [:]).totalLeft == nil)
        #expect(UsageSnapshot(providers: [.claude: ProviderUsage(session: nil, weekly: nil)]).totalLeft == nil)
    }

    @Test func updatingReplacesOneProvider() {
        let base = UsageSnapshot(providers: [.claude: ProviderUsage(session: window(1), weekly: nil)])
        let updated = base.updating(.codex, with: ProviderUsage(session: window(2), weekly: nil))
        #expect(updated[.claude] == base[.claude])
        #expect(updated[.codex]?.session == window(2))
    }

    @Test func fetcherAsksForOneProviderPerCall() {
        #expect(CodexBarFetcher.arguments(for: .claude) == ["usage", "--provider", "claude", "--format", "json"])
        #expect(CodexBarFetcher.arguments(for: .codex) == ["usage", "--provider", "codex", "--format", "json"])
    }
}
