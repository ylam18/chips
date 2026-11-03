import AppKit
import SwiftUI
import UsageCore

/// Menu bar label: a pile of poker chips that shrinks as total usage left drops.
struct ChipStackLabel: View {
    let controller: RefreshController

    var body: some View {
        let left = controller.snapshot?.totalLeft
        Image(nsImage: ChipStackIcon.image(tier: left.map(ChipTier.init(left:)), dimmed: controller.isStale))
            .accessibilityLabel(left.map { "\(Int(($0 * 100).rounded()))% of total usage left" } ?? "Usage unavailable")
    }
}

/// Side-on casino chip columns, arranged like a player's stack: a back row and a front row. Few,
/// large chips with heavy outlines so the pile reads at menu bar size. Drawn in a 24×18 pt
/// top-left-origin space.
enum ChipStackIcon {
    static let size = NSSize(width: 24, height: 18)
    private static let chipWidth: CGFloat = 7
    private static let chipHeight: CGFloat = 2.5
    private static let backRowBase: CGFloat = 15.6
    private static let frontRowBase: CGFloat = 17.6

    private enum Chip {
        case yellow, orange, navy

        var face: NSColor {
            switch self {
            case .yellow: hex(0xF4B400)
            case .orange: hex(0xEF5A2A)
            case .navy: hex(0x2C3C94)
            }
        }

        var spots: NSColor {
            self == .yellow ? hex(0x1A1A1A) : hex(0xFFFFFF)
        }
    }

    private struct Column {
        let x: CGFloat
        let count: Int
        let chip: Chip
    }

    /// Back row first so the front row overlaps it.
    private static func layout(for tier: ChipTier) -> (back: [Column], front: [Column]) {
        switch tier {
        case .full:
            ([Column(x: 4.5, count: 5, chip: .yellow), Column(x: 12.5, count: 5, chip: .navy)],
             [Column(x: 0.5, count: 4, chip: .orange), Column(x: 8.5, count: 5, chip: .yellow), Column(x: 16.5, count: 4, chip: .orange)])
        case .most:
            ([Column(x: 4.5, count: 4, chip: .navy), Column(x: 12.5, count: 4, chip: .yellow)],
             [Column(x: 0.5, count: 3, chip: .yellow), Column(x: 8.5, count: 3, chip: .orange), Column(x: 16.5, count: 2, chip: .yellow)])
        case .half:
            ([Column(x: 8.5, count: 4, chip: .yellow)],
             [Column(x: 4.5, count: 3, chip: .orange), Column(x: 12.5, count: 3, chip: .yellow)])
        case .short:
            ([], [Column(x: 8.5, count: 3, chip: .yellow)])
        case .empty:
            ([], [])
        }
    }

    /// `tier` `nil` (no data yet) draws the empty outline. Not a template image, so the chip
    /// colours survive in the menu bar.
    static func image(tier: ChipTier?, dimmed: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setAlpha(dimmed ? 0.4 : 1)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { context.endTransparencyLayer() }

            let tier = tier ?? .empty
            if tier == .empty {
                drawEmptyOutline()
                return true
            }
            let (back, front) = layout(for: tier)
            back.forEach { draw($0, base: backRowBase) }
            front.forEach { draw($0, base: frontRowBase) }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ column: Column, base: CGFloat) {
        let outline = NSColor.black.withAlphaComponent(0.85)
        for index in 0..<column.count {
            let y = base - CGFloat(index + 1) * chipHeight
            let side = NSBezierPath(roundedRect: NSRect(x: column.x, y: y, width: chipWidth, height: chipHeight - 0.2),
                                    xRadius: 0.8, yRadius: 0.8)
            column.chip.face.setFill()
            side.fill()

            // Edge stripes, staggered on alternate chips like a real stack.
            column.chip.spots.setFill()
            let stagger: CGFloat = index.isMultiple(of: 2) ? 0 : 0.6
            for offset in [1.2, 4.4] as [CGFloat] {
                NSRect(x: column.x + offset + stagger, y: y + 0.45, width: 1.2, height: chipHeight - 1.1).fill()
            }

            side.lineWidth = 0.5
            outline.setStroke()
            side.stroke()
        }

        // Top face of the stack.
        let top = base - CGFloat(column.count) * chipHeight
        let face = NSBezierPath(ovalIn: NSRect(x: column.x, y: top - 1.2, width: chipWidth, height: 2.4))
        column.chip.face.setFill()
        face.fill()
        face.lineWidth = 0.5
        outline.setStroke()
        face.stroke()
        let inlay = NSBezierPath(ovalIn: NSRect(x: column.x + 1.6, y: top - 0.6, width: chipWidth - 3.2, height: 1.2))
        inlay.lineWidth = 0.5
        column.chip.spots.setStroke()
        inlay.stroke()
    }

    /// Where the chips were: a faint dashed chip outline that follows the menu bar's appearance.
    private static func drawEmptyOutline() {
        let outline = NSBezierPath(ovalIn: NSRect(x: 7.5, y: 13.6, width: 9, height: 3.4))
        outline.lineWidth = 1
        outline.setLineDash([1.5, 1], count: 2, phase: 0)
        NSColor.labelColor.withAlphaComponent(0.6).setStroke()
        outline.stroke()
    }
}

private func hex(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
}
