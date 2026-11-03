import SwiftUI
import UsageCore

/// Colours from the approved mockup ("A · Two bars").
enum Palette {
    static func color(for provider: Provider) -> Color {
        Color(nsColor: nsColor(for: provider))
    }

    private static func nsColor(for provider: Provider) -> NSColor {
        switch provider {
        case .claude: NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        case .codex: NSColor(srgbRed: 0x8E / 255, green: 0xA4 / 255, blue: 0xFF / 255, alpha: 1)
        }
    }
}
