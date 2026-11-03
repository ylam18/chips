import Foundation

public protocol UsageFetching: Sendable {
    func fetch(_ provider: Provider) async throws -> ProviderUsage
}

/// Reads usage through the CodexBar CLI, which reuses CodexBar's own logins.
/// The command is fixed here and nowhere else; nothing user-supplied reaches it.
public struct CodexBarFetcher: UsageFetching {
    /// Where the CLI can live, in preference order: Homebrew (Apple silicon, Intel), then the copy
    /// inside the app bundle that Homebrew links to.
    public static let executableCandidates = [
        "/opt/homebrew/bin/codexbar",
        "/usr/local/bin/codexbar",
        "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
    ].map { URL(fileURLWithPath: $0) }
    /// One call per provider, so the fast one (Codex ~1 s) isn't held back by the slow one
    /// (Claude ~10 s, via CodexBar driving the `claude` CLI).
    public static func arguments(for provider: Provider) -> [String] {
        ["usage", "--provider", provider.rawValue, "--format", "json"]
    }
    /// Anything past this is treated as hung.
    public static let timeout: TimeInterval = 30

    private let runner: CLIRunner

    public init(runner: CLIRunner = CLIRunner()) {
        self.runner = runner
    }

    public func fetch(_ provider: Provider) async throws -> ProviderUsage {
        guard let executable = Self.resolveExecutable() else {
            throw CLIError.notFound(path: Self.executableCandidates[0].path)
        }
        let data: Data
        do {
            data = try await runner.run(
                executable: executable,
                arguments: Self.arguments(for: provider),
                environment: Self.environment(
                    base: ProcessInfo.processInfo.environment,
                    home: FileManager.default.homeDirectoryForCurrentUser.path
                ),
                timeout: Self.timeout
            )
        } catch let error as CLIError {
            // CodexBar exits non-zero with its reason as JSON on stdout; surface that reason.
            if case .failed(_, _, let stdout) = error, let message = UsageSnapshot.errorMessage(in: stdout, for: provider) {
                throw UsageDecodingError.providerError(provider, message)
            }
            throw error
        }
        return try Self.usage(for: provider, from: data)
    }

    /// Picks this provider's usage out of CLI output, turning CodexBar errors and empty answers
    /// into errors so the controller keeps the last good data.
    static func usage(for provider: Provider, from data: Data) throws -> ProviderUsage {
        if let message = UsageSnapshot.errorMessage(in: data, for: provider) {
            throw UsageDecodingError.providerError(provider, message)
        }
        guard let usage = try UsageSnapshot.decode(data)[provider] else {
            throw UsageDecodingError.missingProvider(provider)
        }
        guard usage.session != nil || usage.weekly != nil else {
            throw UsageDecodingError.noWindows(provider)
        }
        return usage
    }

    static func resolveExecutable(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        executableCandidates.first { isExecutable($0.path) }
    }

    /// Apps launched from Finder get a minimal PATH, which would hide the `codex`/`claude` CLIs
    /// CodexBar falls back to. Set it explicitly.
    static func environment(base: [String: String], home: String) -> [String: String] {
        var environment = base
        environment["PATH"] = ["/opt/homebrew/bin", "\(home)/.local/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .joined(separator: ":")
        return environment
    }
}
