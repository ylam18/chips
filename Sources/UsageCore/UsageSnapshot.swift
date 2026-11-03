import Foundation

public enum Provider: String, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// One rate-limit window (the 5-hour session or the weekly limit).
public struct UsageWindow: Equatable, Sendable {
    /// 0–100, clamped.
    public let usedPercent: Double
    /// `nil` when the CLI did not report a reset time.
    public let resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
    }

    /// 0–100, what the popover shows.
    public var leftPercent: Double { 100 - usedPercent }
}

/// A `nil` window means the CLI did not report it; the UI shows it as unavailable, never as 0%.
public struct ProviderUsage: Equatable, Sendable {
    public let session: UsageWindow?
    public let weekly: UsageWindow?

    public init(session: UsageWindow?, weekly: UsageWindow?) {
        self.session = session
        self.weekly = weekly
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    /// Providers absent from the CLI output are absent here.
    public let providers: [Provider: ProviderUsage]

    public init(providers: [Provider: ProviderUsage]) {
        self.providers = providers
    }

    public subscript(provider: Provider) -> ProviderUsage? { providers[provider] }

    /// A copy with one provider's usage replaced.
    public func updating(_ provider: Provider, with usage: ProviderUsage) -> UsageSnapshot {
        var providers = providers
        providers[provider] = usage
        return UsageSnapshot(providers: providers)
    }

    /// Fraction (0–1) of total usage left: the average of what's left across every reported
    /// window (5-hour and weekly, all providers). `nil` when no window was reported.
    public var totalLeft: Double? {
        let left = providers.values
            .flatMap { [$0.session, $0.weekly] }
            .compactMap { $0.map { $0.leftPercent / 100 } }
        guard !left.isEmpty else { return nil }
        return left.reduce(0, +) / Double(left.count)
    }
}

public enum UsageDecodingError: Error, Equatable, LocalizedError {
    case malformed(String)
    case noKnownProviders
    case missingProvider(Provider)
    /// CodexBar answered for the provider but reported no usage windows.
    case noWindows(Provider)
    /// CodexBar's own error message for the provider (e.g. not signed in).
    case providerError(Provider, String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): "Unreadable CodexBar output: \(detail)"
        case .noKnownProviders: "CodexBar returned no Claude or Codex usage"
        case .missingProvider(let provider): "CodexBar returned no \(provider.displayName) usage"
        case .noWindows(let provider): "CodexBar reported no \(provider.displayName) limits"
        case .providerError(_, let message): message
        }
    }
}

extension UsageSnapshot {
    /// Decodes `codexbar usage --format json` output. Only the 5-hour (`primary`) and weekly
    /// (`secondary`) windows are read; every other field is ignored. Entries CodexBar marks with
    /// an `error` are skipped — see `errorMessage(in:for:)`.
    public static func decode(_ data: Data) throws -> UsageSnapshot {
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw UsageDecodingError.malformed(String(describing: error))
        }

        var providers: [Provider: ProviderUsage] = [:]
        for entry in entries where entry.error == nil {
            guard let provider = Provider(rawValue: entry.provider) else { continue }
            providers[provider] = ProviderUsage(
                session: entry.usage?.primary.map(UsageWindow.init),
                weekly: entry.usage?.secondary.map(UsageWindow.init)
            )
        }
        guard !providers.isEmpty else { throw UsageDecodingError.noKnownProviders }
        return UsageSnapshot(providers: providers)
    }

    /// CodexBar's error message for `provider`, if the output carries one.
    public static func errorMessage(in data: Data, for provider: Provider) -> String? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return entries.first { $0.provider == provider.rawValue && $0.error != nil }
            .map { $0.error?.message ?? "CodexBar reported an error" }
    }

    private struct Entry: Decodable {
        let provider: String
        let usage: Usage?
        let error: EntryError?
    }

    private struct EntryError: Decodable {
        let message: String?
    }

    private struct Usage: Decodable {
        let primary: Window?
        let secondary: Window?
    }

    fileprivate struct Window: Decodable {
        let usedPercent: Double
        let resetsAt: String?
    }
}

private extension UsageWindow {
    init(_ window: UsageSnapshot.Window) {
        self.init(usedPercent: window.usedPercent, resetsAt: window.resetsAt.flatMap(ISO8601.parse))
    }
}

enum ISO8601 {
    private static let plain = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func parse(_ string: String) -> Date? {
        (try? plain.parse(string)) ?? (try? fractional.parse(string))
    }
}
