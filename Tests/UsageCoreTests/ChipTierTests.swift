import Testing
@testable import UsageCore

@Suite struct ChipTierTests {
    @Test(arguments: [
        (1.0, ChipTier.full), (0.76, .full), (0.755, .full),
        (0.751, .most), (0.75, .most), (0.51, .most),
        (0.50, .half), (0.26, .half),
        (0.2504, .short), (0.25, .short), (0.14, .short), (0.01, .short), (0.005, .short),
        (0.004, .empty), (0.0, .empty),
    ])
    /// Steps follow the rounded whole percent, matching the accessibility label.
    func tierFollows25PercentSteps(left: Double, expected: ChipTier) {
        #expect(ChipTier(left: left) == expected)
    }
}
