import Foundation

/// A small thread-safe LRU cache bounded by entry count *and* total cost.
///
/// Replaces `NSCache` where the eviction behaviour has to be predictable and
/// testable: `NSCache` evicts in an undocumented order and only treats its
/// limits as hints, so the preview's memory bound could not be pinned by a test.
/// Here the rules are exact:
/// - a lookup marks the entry most recently used;
/// - an insert that pushes the cache past either limit evicts least recently
///   used entries until both hold again (never the entry just inserted);
/// - an entry whose own cost exceeds `totalCostLimit` is not stored at all, and
///   replaces nothing — caching it would immediately flush everything else;
/// - `removeAll()` (the memory-pressure response) empties it at once.
///
/// `@unchecked Sendable` is sound: every stored property is only touched while
/// holding `lock`. Values are handed out as-is; a reference-type value is only
/// as thread-safe as its own type (the preview caches immutable bundles).
public final class CostBoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    public let countLimit: Int
    public let totalCostLimit: Int

    private struct Entry {
        let value: Value
        let cost: Int
        /// Monotonic recency stamp; larger = more recently used.
        var stamp: UInt64
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var cost = 0

    /// - Parameters:
    ///   - countLimit: most entries kept (at least 1).
    ///   - totalCostLimit: most summed cost kept (at least 1).
    public init(countLimit: Int, totalCostLimit: Int) {
        self.countLimit = max(1, countLimit)
        self.totalCostLimit = max(1, totalCostLimit)
    }

    /// The cached value for `key`, marking it most recently used.
    public func value(forKey key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.stamp = clock
        entries[key] = entry
        return entry.value
    }

    /// Stores `value` under `key` with `cost` (negative counts as 0), replacing
    /// any previous entry, then evicts least recently used entries until both
    /// limits hold. Returns `false` (and leaves the cache untouched) when `cost`
    /// alone exceeds `totalCostLimit`.
    @discardableResult
    public func insert(_ value: Value, forKey key: Key, cost: Int) -> Bool {
        let cost = max(0, cost)
        lock.lock()
        defer { lock.unlock() }
        guard cost <= totalCostLimit else { return false }
        if let old = entries.removeValue(forKey: key) {
            self.cost -= old.cost
        }
        clock &+= 1
        entries[key] = Entry(value: value, cost: cost, stamp: clock)
        self.cost += cost
        while entries.count > countLimit || self.cost > totalCostLimit {
            // Linear scan: the preview caches hold a few dozen entries at most.
            guard let victim = entries.filter({ $0.key != key }).min(by: { $0.value.stamp < $1.value.stamp }) else { break }
            entries.removeValue(forKey: victim.key)
            self.cost -= victim.value.cost
        }
        return true
    }

    /// Drops `key`'s entry, if any.
    public func removeValue(forKey key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
    }

    /// Empties the cache — the memory-pressure response.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        cost = 0
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Sum of the stored entries' costs.
    public var totalCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return cost
    }

    /// Keys from least to most recently used — the order eviction follows.
    public var keysByRecency: [Key] {
        lock.lock()
        defer { lock.unlock() }
        return entries.sorted { $0.value.stamp < $1.value.stamp }.map(\.key)
    }
}

/// Limits and cost accounting for the Quick Look preview's bundle cache (the
/// extension keeps `CostBoundedCache<String, MIQPreviewBundle>` built from
/// these), kept in MIQCore so the numbers and the arithmetic are tested.
public enum PreviewCachePolicy {
    /// At most this many (file, settings) bundles. A bundle is ≤ 3 MB (three
    /// ≤ 512² RGBA slices, or a quarter of that in 8-bit grey), so the cost
    /// limit normally binds first.
    public static let countLimit = 24

    /// Upper bound on cached slice pixels (48 MiB). The preview extension is a
    /// long-lived process shared by every preview the user opens; without a
    /// limit the cache would only shrink under system memory pressure, by which
    /// point the extension may already be a jetsam candidate.
    public static let totalCostLimitBytes = 48 * 1024 * 1024

    /// Resident bytes of one 8-bit-per-channel image: `width × height ×
    /// bytesPerPixel` (1 for `Gray8Bitmap`, 4 for `RGBABitmap`). Non-positive
    /// dimensions cost 0; an overflowing product saturates at `Int.max`.
    public static func costBytes(width: Int, height: Int, bytesPerPixel: Int) -> Int {
        guard width > 0, height > 0, bytesPerPixel > 0 else { return 0 }
        let (area, o1) = width.multipliedReportingOverflow(by: height)
        let (bytes, o2) = area.multipliedReportingOverflow(by: bytesPerPixel)
        return (o1 || o2) ? Int.max : bytes
    }

    /// Actual pixel-buffer size of a rendered slice.
    public static func costBytes(of bitmap: PreviewSliceBitmap) -> Int {
        switch bitmap {
        case .gray(let gray): return gray.pixels.count
        case .rgba(let rgba): return rgba.pixels.count
        }
    }

    /// Summed cost of a bundle's slices, saturating instead of overflowing.
    public static func bundleCost<S: Sequence>(_ bitmaps: S) -> Int where S.Element == PreviewSliceBitmap {
        bitmaps.reduce(0) { total, bitmap in
            let (sum, overflow) = total.addingReportingOverflow(costBytes(of: bitmap))
            return overflow ? Int.max : sum
        }
    }

    /// A cache configured with this policy's limits.
    public static func makeCache<Value>() -> CostBoundedCache<String, Value> {
        CostBoundedCache(countLimit: countLimit, totalCostLimit: totalCostLimitBytes)
    }
}

/// A rendered slice in the cheapest pixel format that represents it exactly:
/// one grey byte per pixel for a windowed grayscale slice, RGBA for colour data,
/// segmentation LUTs and overlays. The AppKit bridge wraps either in a CGImage
/// without copying.
public enum PreviewSliceBitmap: Sendable {
    case gray(Gray8Bitmap)
    case rgba(RGBABitmap)

    public var width: Int {
        switch self {
        case .gray(let b): return b.width
        case .rgba(let b): return b.width
        }
    }

    public var height: Int {
        switch self {
        case .gray(let b): return b.height
        case .rgba(let b): return b.height
        }
    }
}

extension SliceImage {
    /// `makeGray8()` for a grayscale slice, else `rgbaBitmap()`; `nil` only for a
    /// buffer that doesn't match its dimensions. The grey bytes equal the R (= G
    /// = B) bytes the RGBA path would produce, so the displayed image is
    /// unchanged — at a quarter of the memory.
    public func previewBitmap() -> PreviewSliceBitmap? {
        if let gray = makeGray8() { return .gray(gray) }
        return rgbaBitmap().map(PreviewSliceBitmap.rgba)
    }
}
