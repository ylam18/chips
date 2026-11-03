import Foundation
import Observation

/// Holds the latest usage and keeps it fresh. One refresh runs at a time; within it each provider
/// is fetched in parallel and shown as soon as it arrives. A provider that fails keeps its last
/// good data and records a provider-named error.
@MainActor
@Observable
public final class RefreshController {
    public private(set) var snapshot: UsageSnapshot?
    /// Age of the oldest provider data shown: the earliest of each provider's last success.
    public var updatedAt: Date? { providerUpdatedAt.values.min() }
    /// Dims the menu bar icon. Stored (not computed from the clock) so the label redraws when it
    /// flips; re-evaluated on every result and on every scheduler tick.
    public private(set) var isStale = true
    public var isRefreshing: Bool { inFlight != nil }

    /// One line per failing provider, or `nil` when everything is current.
    public var lastError: String? {
        let lines = Provider.allCases.compactMap { provider in
            errors[provider].map { "\(provider.displayName): \($0)" }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Data older than this dims the menu bar icon.
    public static let staleAfter: TimeInterval = 15 * 60

    private let fetcher: UsageFetching
    private let now: @Sendable () -> Date
    private var errors: [Provider: String] = [:]
    private var providerUpdatedAt: [Provider: Date] = [:]
    private var inFlight: Task<Void, Never>?
    private var schedule: Task<Void, Never>?

    public init(fetcher: UsageFetching, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.now = now
    }

    /// Fetches now, then every `interval` seconds until `cancel()`.
    public func start(interval: TimeInterval = 5 * 60) {
        refresh()
        schedule?.cancel()
        // Holds `self` weakly between ticks, so the loop ends if the controller goes away.
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return // cancelled
                }
                guard let self else { return }
                self.updateStaleness()
                self.refresh()
            }
        }
    }

    /// Refreshes when the data is older than `maxAge` (or missing).
    public func refreshIfOlder(than maxAge: TimeInterval = 60) {
        guard let updatedAt, now().timeIntervalSince(updatedAt) < maxAge else {
            refresh()
            return
        }
    }

    /// Starts a refresh unless one is already running; returns the running task when it starts one.
    @discardableResult
    public func refresh() -> Task<Void, Never>? {
        guard inFlight == nil else { return nil }
        let fetcher = fetcher
        let task = Task { [weak self] in
            await withTaskGroup(of: (Provider, Result<ProviderUsage, Error>).self) { group in
                for provider in Provider.allCases {
                    group.addTask {
                        do {
                            return (provider, .success(try await fetcher.fetch(provider)))
                        } catch {
                            return (provider, .failure(error))
                        }
                    }
                }
                for await (provider, result) in group {
                    self?.apply(result, for: provider)
                }
            }
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }

    /// Stops the schedule and terminates fetches in progress (used on quit).
    public func cancel() {
        schedule?.cancel()
        schedule = nil
        inFlight?.cancel()
    }

    /// Stale when any provider errored, any provider has no data yet, or the oldest data is past
    /// `staleAfter`.
    public func updateStaleness() {
        let stale: Bool
        if !errors.isEmpty || providerUpdatedAt.count < Provider.allCases.count {
            stale = true
        } else if let updatedAt {
            stale = now().timeIntervalSince(updatedAt) > Self.staleAfter
        } else {
            stale = true
        }
        if stale != isStale { isStale = stale }
    }

    private func apply(_ result: Result<ProviderUsage, Error>, for provider: Provider) {
        switch result {
        case .success(let usage):
            snapshot = (snapshot ?? UsageSnapshot(providers: [:])).updating(provider, with: usage)
            providerUpdatedAt[provider] = now()
            errors[provider] = nil
        case .failure(is CancellationError):
            return // shutting down; not a usage problem
        case .failure(let error):
            errors[provider] = error.localizedDescription
        }
        updateStaleness()
    }
}
