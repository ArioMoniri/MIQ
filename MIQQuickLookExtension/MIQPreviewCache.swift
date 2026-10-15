import AppKit
import MIQCore

/// Cached bundle of everything the preview UI needs for one (file, settings)
/// combination. Caching at this granularity lets `load()` skip parsing,
/// decompression, slicing, and windowing entirely on a hit.
final class MIQPreviewBundle: NSObject {
    let slices: [SlicePlane: NSImage]
    let orientations: [SlicePlane: SliceOrientationLabels]
    let metadataEntries: [MetadataEntry]
    /// Always-visible panel warnings (orientation caution, sidecar mismatch).
    let panelWarnings: [String]
    /// Format-specific rows after the configurable ones (DICOM technical rows).
    let extraEntries: [MetadataEntry]
    /// Volumes along the 4th axis, so a cache hit shows the Volumes scrubber at
    /// once rather than only after the interactive state is re-read.
    let volumeCount: Int
    /// Approximate resident bytes of the three slice images (RGBA, 4 bytes per
    /// pixel), the `NSCache` cost so `totalCostLimit` bounds real memory.
    let costBytes: Int

    init(slices: [SlicePlane: NSImage],
         orientations: [SlicePlane: SliceOrientationLabels],
         metadataEntries: [MetadataEntry],
         panelWarnings: [String] = [],
         extraEntries: [MetadataEntry] = [],
         volumeCount: Int) {
        self.slices = slices
        self.orientations = orientations
        self.metadataEntries = metadataEntries
        self.panelWarnings = panelWarnings
        self.extraEntries = extraEntries
        self.volumeCount = volumeCount
        self.costBytes = slices.values.reduce(0) { $0 + Self.approximateBytes(of: $1) }
    }

    /// Pixel dimensions × 4 (the slice images are 8-bit RGBA, see
    /// `MIQImageBridge`). Falls back to the point size, which equals the pixel
    /// size for those images.
    private static func approximateBytes(of image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return max(0, Int(image.size.width)) * max(0, Int(image.size.height)) * 4
    }
}

enum MIQPreviewCache {
    /// At most this many (file, settings) bundles. A bundle is ≤ 3 MB (three
    /// ≤ 512² RGBA slices), so the cost limit below normally binds first.
    static let countLimit = 24
    /// Upper bound on cached slice pixels (48 MiB). The preview extension is a
    /// long-lived process shared by every preview the user opens; without a
    /// limit `NSCache` only evicts under system memory pressure, by which point
    /// the extension may already be a jetsam candidate.
    static let totalCostLimitBytes = 48 * 1024 * 1024

    /// Owns the cache and the memory-pressure source that empties it.
    ///
    /// `@unchecked Sendable` is sound: both stored properties are immutable
    /// references, `NSCache` is documented thread-safe (all its methods may be
    /// called from any thread), and the dispatch source is only configured in
    /// `init` before it is published. This replaces a `nonisolated(unsafe)`
    /// static, which made the same claim without stating why.
    private final class Storage: @unchecked Sendable {
        let cache = NSCache<NSString, MIQPreviewBundle>()
        private let memoryPressureSource: DispatchSourceMemoryPressure

        init() {
            cache.countLimit = MIQPreviewCache.countLimit
            cache.totalCostLimit = MIQPreviewCache.totalCostLimitBytes
            // A cache hit only saves a re-parse; under memory pressure that is
            // never worth keeping pixels for. Drop everything on .warning too,
            // not just .critical: the extension is small fry next to Finder.
            memoryPressureSource = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: .global(qos: .utility)
            )
            // Captures the Sendable box, not the NSCache, so the handler type-checks
            // whether or not the SDK marks it @Sendable.
            memoryPressureSource.setEventHandler { [weak self] in
                self?.cache.removeAllObjects()
            }
            memoryPressureSource.resume()
        }
    }

    private static let storage = Storage()

    static func bundle(for key: String) -> MIQPreviewBundle? {
        return storage.cache.object(forKey: key as NSString)
    }

    static func insert(_ bundle: MIQPreviewBundle, for key: String) {
        storage.cache.setObject(bundle, forKey: key as NSString, cost: bundle.costBytes)
    }

    /// Key derivable without parsing. File path + mtime uniquely identifies
    /// the file's contents; any setting that changes pixel output must be
    /// included here (see CLAUDE.md).
    static func makeKey(
        fileURL: URL,
        maxDimension: Int,
        options: RenderingOptions
    ) -> String {
        let path = fileURL.standardizedFileURL.path
        let modDate: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            modDate = String(format: "%.6f", date.timeIntervalSinceReferenceDate)
        } else {
            modDate = ""
        }
        return "\(path)|\(modDate)|\(maxDimension)|\(options.lowerPercentile)|\(options.upperPercentile)|\(options.orientation.rawValue)|\(options.segmentationColoring.rawValue)"
    }
}
