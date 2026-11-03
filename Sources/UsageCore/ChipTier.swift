/// How big the menu bar chip stack is, in 25% steps of total usage left. Steps use the same
/// rounded whole percent the label reads out, so the stack never disagrees with it.
public enum ChipTier: Int, CaseIterable, Sendable {
    case empty   // 0%
    case short   // 1–25%
    case half    // 26–50%
    case most    // 51–75%
    case full    // 76–100%

    /// `left` is a 0–1 fraction.
    public init(left: Double) {
        switch (left * 100).rounded() {
        case ..<1: self = .empty
        case ...25: self = .short
        case ...50: self = .half
        case ...75: self = .most
        default: self = .full
        }
    }
}
