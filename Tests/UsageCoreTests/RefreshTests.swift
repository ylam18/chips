import Foundation
import Testing
@testable import UsageCore

/// Fetcher whose calls block per provider until released, so tests control arrival order.
private actor GatedFetcher: UsageFetching {
    private(set) var calls: [Provider: Int] = [:]
    private(set) var cancelled = 0
    private var waiters: [Provider: CheckedContinuation<Void, Never>] = [:]
    private var results: [Provider: [Result<ProviderUsage, Error>]]

    init(results: [Provider: [Result<ProviderUsage, Error>]]) {
        self.results = results
    }

    nonisolated func fetch(_ provider: Provider) async throws -> ProviderUsage {
        try await withTaskCancellationHandler {
            try await gatedFetch(provider)
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    private func gatedFetch(_ provider: Provider) async throws -> ProviderUsage {
        calls[provider, default: 0] += 1
        await withCheckedContinuation { waiters[provider] = $0 }
        if Task.isCancelled { throw CancellationError() }
        return try results[provider, default: []].removeFirst().get()
    }

    func release(_ provider: Provider) {
        waiters.removeValue(forKey: provider)?.resume()
    }

    func isWaiting(_ provider: Provider) -> Bool { waiters[provider] != nil }

    private func cancelAll() {
        cancelled += 1
        Provider.allCases.forEach(release)
    }
}

/// Settable clock for staleness tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private struct FetchFailed: Error, LocalizedError {
    var errorDescription: String? { "network down" }
}

private let claude = ProviderUsage(session: UsageWindow(usedPercent: 10, resetsAt: nil), weekly: nil)
private let codex = ProviderUsage(session: UsageWindow(usedPercent: 20, resetsAt: nil), weekly: nil)

@MainActor
@Suite struct RefreshTests {
    private func waitUntilWaiting(_ fetcher: GatedFetcher, _ providers: Provider...) async {
        for provider in providers {
            while !(await fetcher.isWaiting(provider)) { await Task.yield() }
        }
    }

    /// Yields until `condition` holds; the controller applies results on the main actor.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    @Test func overlappingRefreshesRunOnce() async {
        let fetcher = GatedFetcher(results: [.claude: [.success(claude)], .codex: [.success(codex)]])
        let controller = RefreshController(fetcher: fetcher)

        let first = controller.refresh()
        #expect(first != nil)
        #expect(controller.refresh() == nil)
        #expect(controller.isRefreshing)

        await waitUntilWaiting(fetcher, .claude, .codex)
        await fetcher.release(.claude)
        await fetcher.release(.codex)
        await first?.value

        #expect(await fetcher.calls == [.claude: 1, .codex: 1])
        #expect(controller.snapshot == UsageSnapshot(providers: [.claude: claude, .codex: codex]))
        #expect(controller.lastError == nil)
        #expect(!controller.isRefreshing)
    }

    @Test func eachProviderAppearsAsItArrives() async {
        let fetcher = GatedFetcher(results: [.claude: [.success(claude)], .codex: [.success(codex)]])
        let controller = RefreshController(fetcher: fetcher)

        let task = controller.refresh()
        await waitUntilWaiting(fetcher, .claude, .codex)
        await fetcher.release(.codex)
        await settle { controller.snapshot?[.codex] != nil }

        #expect(controller.snapshot?[.codex] == codex)
        #expect(controller.snapshot?[.claude] == nil)
        #expect(controller.isRefreshing)

        await fetcher.release(.claude)
        await task?.value
        #expect(controller.snapshot?[.claude] == claude)
    }

    @Test func oneProviderFailingKeepsItsLastGoodDataAndNamesIt() async {
        let fetcher = GatedFetcher(results: [
            .claude: [.success(claude), .failure(FetchFailed())],
            .codex: [.success(codex), .success(codex)],
        ])
        let controller = RefreshController(fetcher: fetcher)

        for _ in 0..<2 {
            let task = controller.refresh()
            await waitUntilWaiting(fetcher, .claude, .codex)
            await fetcher.release(.claude)
            await fetcher.release(.codex)
            await task?.value
        }

        #expect(controller.snapshot?[.claude] == claude)
        #expect(controller.snapshot?[.codex] == codex)
        #expect(controller.lastError == "Claude: network down")
        #expect(controller.isStale)
    }

    @Test func laterSuccessClearsThatProvidersError() async {
        let fetcher = GatedFetcher(results: [
            .claude: [.failure(FetchFailed()), .success(claude)],
            .codex: [.success(codex), .success(codex)],
        ])
        let controller = RefreshController(fetcher: fetcher)

        for expectedError in ["Claude: network down", nil] as [String?] {
            let task = controller.refresh()
            await waitUntilWaiting(fetcher, .claude, .codex)
            await fetcher.release(.claude)
            await fetcher.release(.codex)
            await task?.value
            #expect(controller.lastError == expectedError)
        }
        #expect(!controller.isStale)
    }

    @Test func cancelStopsInFlightFetchWithoutError() async {
        let fetcher = GatedFetcher(results: [.claude: [.success(claude)], .codex: [.success(codex)]])
        let controller = RefreshController(fetcher: fetcher)

        let task = controller.refresh()
        await waitUntilWaiting(fetcher, .claude, .codex)
        controller.cancel()
        await task?.value

        #expect(await fetcher.cancelled >= 1)
        #expect(controller.snapshot == nil)
        #expect(controller.lastError == nil)
        #expect(!controller.isRefreshing)
    }

    @Test func stalenessIsReevaluatedAsTimePasses() async {
        let clock = TestClock()
        let fetcher = GatedFetcher(results: [.claude: [.success(claude)], .codex: [.success(codex)]])
        let controller = RefreshController(fetcher: fetcher, now: { clock.now })
        #expect(controller.isStale) // no data yet

        let task = controller.refresh()
        await waitUntilWaiting(fetcher, .claude, .codex)
        await fetcher.release(.codex)
        await settle { controller.snapshot?[.codex] != nil }
        #expect(controller.isStale) // Claude still missing

        await fetcher.release(.claude)
        await task?.value
        #expect(!controller.isStale)

        clock.advance(by: RefreshController.staleAfter + 1)
        controller.updateStaleness()
        #expect(controller.isStale)
    }

    @Test func updatedAtIsTheOldestProvider() async {
        let clock = TestClock()
        let fetcher = GatedFetcher(results: [.claude: [.success(claude)], .codex: [.success(codex)]])
        let controller = RefreshController(fetcher: fetcher, now: { clock.now })
        let started = clock.now

        let task = controller.refresh()
        await waitUntilWaiting(fetcher, .claude, .codex)
        await fetcher.release(.claude)
        await settle { controller.snapshot?[.claude] != nil }
        clock.advance(by: 120)
        await fetcher.release(.codex)
        await task?.value

        #expect(controller.updatedAt == started)
    }

    @Test func refreshIfOlderSkipsFreshData() async {
        let fetcher = GatedFetcher(results: [.claude: [.success(claude)], .codex: [.success(codex)]])
        let controller = RefreshController(fetcher: fetcher)
        let first = controller.refresh()
        await waitUntilWaiting(fetcher, .claude, .codex)
        await fetcher.release(.claude)
        await fetcher.release(.codex)
        await first?.value

        controller.refreshIfOlder(than: 60)
        #expect(!controller.isRefreshing)
        #expect(await fetcher.calls == [.claude: 1, .codex: 1])
    }
}
