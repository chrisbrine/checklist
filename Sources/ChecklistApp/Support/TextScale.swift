import Foundation

// Shared across workspace preference suites, including separately hosted Settings.
enum TextScale {
    static let key = "checklist.textScale"
    static let steps: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    static func usesInlineComposer(at scale: Double) -> Bool { scale > 1.3 }
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return steps.min { abs($0 - value) < abs($1 - value) } ?? 1
    }
    static func stepping(_ value: Double, by offset: Int) -> Double {
        let index = steps.firstIndex(of: normalized(value)) ?? 1
        return steps[min(steps.count - 1, max(0, index + offset))]
    }
}

