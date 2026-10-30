import Foundation

/// CL-348: limits apply only to the direction grid; single-item comparison keeps its budget.
public extension MediaPlaybackBudget {
    static let directionGridTakes = 8
    static let directionGridOriginalBytes = 32 * 1024 * 1024
    static let directionGridCacheBytes = 256 * 1024 * 1024
    /// Sum of source pixels for all loaded decoders, each edge at most 1024.
    static let directionGridPixels = 8 * 512 * 512
}
