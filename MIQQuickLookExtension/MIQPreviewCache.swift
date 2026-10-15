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
    /// Resident bytes of the three slice images — their real pixel buffers (1
    /// byte per pixel for 8-bit grey, 4 for RGBA; see `PreviewCachePolicy`), the
    /// cache cost so the cost limit bounds real memory.
    let costBytes: Int

    init(slices: [SlicePlane: NSImage],
         orientations: [SlicePlane: SliceOrientationLabels],
         metadataEntries: [MetadataEntry],
         panelWarnings: [String] = [],
         extraEntries: [MetadataEntry] = [],
         volumeCount: Int,
         costBytes: Int) {
        self.slices = slices
        self.orientations = orientations
        self.metadataEntries = metadataEntries
        self.panelWarnings = panelWarnings
        self.extraEntries = extraEntries
        self.volumeCount = volumeCount
        self.costBytes = costBytes
    }
}

enum MIQPreviewCache {
    /// Owns the cache and the memory-pressure source that empties it.
    ///
    /// The cache is a `CostBoundedCache` (MIQCore) with `PreviewCachePolicy`'s
    /// limits (24 bundles, 48 MiB of slice pixels) rather than an `NSCache`: its
    /// LRU order, cost limit and memory-pressure clear are deterministic and
    /// covered by `CostBoundedCacheTests`, where `NSCache` treats its limits as
    /// hints and evicts in an undocumented order.
    ///
    /// `@unchecked Sendable` is sound: both stored properties are immutable
    /// references, `CostBoundedCache` serialises every access with a lock, the
    /// bundles it holds are immutable after `init`, and the dispatch source is
    /// only configured in `init` before it is published.
    private final class Storage: @unchecked Sendable {
        let cache: CostBoundedCache<String, MIQPreviewBundle> = PreviewCachePolicy.makeCache()
        private let memoryPressureSource: DispatchSourceMemoryPressure

        init() {
            // A cache hit only saves a re-parse; under memory pressure that is
            // never worth keeping pixels for. Drop everything on .warning too,
            // not just .critical: the extension is small fry next to Finder.
            memoryPressureSource = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: .global(qos: .utility)
            )
            // Captures the Sendable box, not the cache, so the handler type-checks
            // whether or not the SDK marks it @Sendable.
            memoryPressureSource.setEventHandler { [weak self] in
                self?.cache.removeAll()
                // So are the decoded volumes of streamed 4D series (the one on
                // screen stays alive through the model's own reference).
                NiftiVolumeReader.purgeAllCaches()
                // The 3D view's GPU textures are just as disposable.
                VolumeRenderer.releaseCachedResources()
            }
            memoryPressureSource.resume()
        }
    }

    private static let storage = Storage()

    static func bundle(for key: String) -> MIQPreviewBundle? {
        return storage.cache.value(forKey: key)
    }

    static func insert(_ bundle: MIQPreviewBundle, for key: String) {
        storage.cache.insert(bundle, forKey: key, cost: bundle.costBytes)
    }

    /// Key derivable without parsing. File path + mtime uniquely identifies
    /// the file's contents; any setting that changes pixel output must be
    /// included here (see CONTRIBUTING.md, "Conventions › Preview cache key") —
    /// `windowFromHeadMask` changes the cold preview's window, so it is part of
    /// the key.
    static func makeKey(
        fileURL: URL,
        maxDimension: Int,
        options: RenderingOptions,
        windowFromHeadMask: Bool = false
    ) -> String {
        let path = fileURL.standardizedFileURL.path
        let modDate: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            modDate = String(format: "%.6f", date.timeIntervalSinceReferenceDate)
        } else {
            modDate = ""
        }
        let headMask = windowFromHeadMask ? "|headMask" : ""
        return "\(path)|\(modDate)|\(maxDimension)|\(options.lowerPercentile)|\(options.upperPercentile)|\(options.orientation.rawValue)|\(options.segmentationColoring.rawValue)\(headMask)"
    }
}
