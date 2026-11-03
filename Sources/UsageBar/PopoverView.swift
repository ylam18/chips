import SwiftUI
import UsageCore

/// The click-open panel: per provider, a 5-hour and a weekly bar of usage left, with reset times.
struct PopoverView: View {
    let controller: RefreshController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Provider.allCases.enumerated()), id: \.element) { index, provider in
                if index > 0 { Divider().padding(.vertical, 10) }
                ProviderSection(provider: provider, usage: controller.snapshot?[provider])
            }
            Divider().padding(.vertical, 10)
            Footer(controller: controller)
        }
        .padding(14)
        .frame(width: 220)
        .onAppear { controller.refreshIfOlder() }
    }
}

private struct ProviderSection: View {
    let provider: Provider
    let usage: ProviderUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Palette.color(for: provider)).frame(width: 7, height: 7)
                Text(provider.displayName).font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.bottom, 8)
            WindowRow(title: "5 hr", window: usage?.session, color: Palette.color(for: provider))
            WindowRow(title: "Week", window: usage?.weekly, color: Palette.color(for: provider))
                .padding(.top, 9)
        }
    }
}

private struct WindowRow: View {
    let title: String
    let window: UsageWindow?
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let window {
                    Text("\(Int(window.leftPercent.rounded()))% left").font(.system(size: 12).monospacedDigit())
                    if let resetsAt = window.resetsAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("· \(ResetFormat.label(for: resetsAt, now: context.date))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                } else {
                    Text("—").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    if let window {
                        Capsule().fill(color).frame(width: proxy.size.width * window.leftPercent / 100)
                    }
                }
            }
            .frame(height: 4)
        }
    }
}

private struct Footer: View {
    let controller: RefreshController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(status(now: context.date))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { controller.refresh() }
                    .disabled(controller.isRefreshing)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))

            if let error = controller.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func status(now: Date) -> String {
        if controller.isRefreshing { return "Updating…" }
        guard let updatedAt = controller.updatedAt else { return "No data yet" }
        let minutes = Int(now.timeIntervalSince(updatedAt) / 60)
        return minutes < 1 ? "Updated just now" : "Updated \(minutes)m ago"
    }
}
