import Foundation

/// A DICOM series stacked from single-frame sibling files.
public struct DICOMSeries: Sendable {
    public let image: MIQImage
    public let info: DICOMTechnicalInfo
    /// Number of files stacked (the volume's depth).
    public let sliceCount: Int
}

/// Opt-in, best-effort assembly of a classic single-frame-per-file DICOM series into a
/// 3D volume.
///
/// Given one file, finds the files that share its `SeriesInstanceUID` (among sibling
/// files in the same folder, or an explicit candidate list), sorts them by Image
/// Position (Patient) projected on the slice normal, and stacks them. The series UID
/// is compared in memory only and never surfaces in any output.
///
/// Every failure is silent (`nil`): a sandboxed Quick Look extension usually may not
/// read sibling files at all, and a mixed or irregular folder should simply fall back
/// to the single-file preview from `MIQParser.parse(url:)`, which never depends on this.
public struct DICOMSeriesAssembler: Sendable {
    /// Maximum number of directory entries inspected.
    public let maxFiles: Int
    /// Maximum size of the assembled pixel payload.
    public let maxTotalBytes: Int

    /// Default `maxTotalBytes` (1 GiB); also bounds the single-file float32 copy
    /// in `MIQParser.decodeDicom`.
    public static let defaultMaxTotalBytes = 1 << 30

    public init(maxFiles: Int = 2048, maxTotalBytes: Int = DICOMSeriesAssembler.defaultMaxTotalBytes) {
        self.maxFiles = maxFiles
        self.maxTotalBytes = maxTotalBytes
    }

    /// Scans the folder containing `url` for the rest of its series. `nil` when the
    /// folder can't be listed, the file has no series UID / geometry, or fewer than two
    /// compatible slices are found.
    public func assembleSeries(containing url: URL) -> DICOMSeries? {
        let folder = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let files = entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= maxFiles else { return nil }
        return assembleSeries(containing: url, candidates: files)
    }

    /// Assembles the largest series among the files directly inside `folder`
    /// (subfolders are not searched): for a folder the user picked, e.g. in the
    /// app's Brain Mask tool, where the folder grant covers its files. Files are
    /// grouped by `SeriesInstanceUID` (compared in memory only); the group with
    /// the most files wins, ties going to the one whose first file sorts first.
    /// `nil` when the folder can't be listed, holds more than `maxFiles` entries,
    /// or no group stacks into a volume of at least two slices.
    public func assembleLargestSeries(inFolder folder: URL) -> DICOMSeries? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ), entries.count <= maxFiles else { return nil }
        let files = entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var groups: [DICOMRedactedUID: [URL]] = [:]
        var order: [DICOMRedactedUID] = []
        for file in files where Self.hasPart10Marker(file) {
            guard let descriptor = Self.load(file), let uid = descriptor.seriesUID else { continue }
            if groups[uid] == nil { order.append(uid) }
            groups[uid, default: []].append(file)
        }
        // Largest first; the stable sort keeps folder order among equals.
        let ranked = order.enumerated()
            .sorted { a, b in
                let (ca, cb) = (groups[a.element]!.count, groups[b.element]!.count)
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map(\.element)
        for uid in ranked {
            let members = groups[uid]!
            guard members.count >= 2 else { break }
            if let series = assembleSeries(containing: members[0], candidates: members) {
                return series
            }
        }
        return nil
    }

    /// Assembles the series of `url` from `candidates` (which may include `url`).
    public func assembleSeries(containing url: URL, candidates: [URL]) -> DICOMSeries? {
        guard let anchor = Self.load(url), let uid = anchor.seriesUID,
              anchor.frames == 1, let orientation = anchor.orientation,
              anchor.framePositions?.count == 1 else { return nil }

        let anchorPath = url.standardizedFileURL.path
        var slices: [DICOMImageDescriptor] = [anchor]
        for candidate in candidates.prefix(maxFiles) where candidate.standardizedFileURL.path != anchorPath {
            guard Self.hasPart10Marker(candidate), let slice = Self.load(candidate),
                  slice.seriesUID == uid, Self.compatible(slice, anchor, orientation: orientation) else { continue }
            slices.append(slice)
        }
        guard slices.count >= 2 else { return nil }

        let normal = DICOMVector.normalize(
            DICOMVector.cross(Array(orientation[0..<3]), Array(orientation[3..<6]))
        ) ?? [0, 0, 1]
        let keyed = slices.map { (slice: $0, key: DICOMVector.dot($0.framePositions![0], normal)) }
            .sorted { $0.key < $1.key }
        // Two files at one position means a multi-echo / multi-phase series (4D):
        // not a single volume, so bail out rather than interleave.
        for i in 1..<keyed.count where abs(keyed[i].key - keyed[i - 1].key) < 1e-3 {
            return nil
        }
        let ordered = keyed.map(\.slice)

        let (total, overflow) = anchor.frameBytes.multipliedReportingOverflow(by: ordered.count)
        guard !overflow, total <= maxTotalBytes else { return nil }

        let sameScaling = ordered.allSatisfy {
            $0.rescaleSlope == anchor.rescaleSlope && $0.rescaleIntercept == anchor.rescaleIntercept
        }
        let storage: Data
        let datatypeOverride: MIQDatatype?
        let scalingOverride: (slope: Float, inter: Float)?
        if sameScaling || anchor.datatype == .rgb24 {
            var combined = Data(capacity: total)
            for slice in ordered {
                let (bytes, offset) = slice.pixelStorage()
                let start = bytes.startIndex + offset
                combined.append(bytes[start..<(start + slice.frameBytes)])
            }
            storage = combined
            datatypeOverride = nil
            scalingOverride = nil
        } else {
            // Per-slice rescale differs: materialise real-world values as float32.
            let samples = anchor.frameSamples
            guard samples.multipliedReportingOverflow(by: 4 * ordered.count).overflow == false,
                  samples * 4 * ordered.count <= maxTotalBytes else { return nil }
            // Written straight into the result: peak memory is one copy, not two.
            var out = Data(count: samples * 4 * ordered.count)
            out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let floats = raw.bindMemory(to: Float.self)
                for (s, slice) in ordered.enumerated() {
                    let (bytes, offset) = slice.pixelStorage()
                    let base = s * samples
                    for i in 0..<samples {
                        let value = slice.rawSample(bytes, offset: offset, index: i)
                        floats[base + i] = Float(value * slice.rescaleSlope + slice.rescaleIntercept)
                    }
                }
            }
            storage = out
            datatypeOverride = .float32
            scalingOverride = (0, 0)
        }

        let positions = ordered.map { $0.framePositions![0] }
        let geometry = DICOMGeometry(
            frames: ordered.count,
            pixelSpacing: anchor.pixelSpacing,
            orientation: orientation,
            framePositions: positions,
            fallbackSliceSpacing: anchor.spacingBetweenSlices ?? anchor.sliceThickness
        )
        let header = anchor.header(
            frames: ordered.count,
            geometry: geometry,
            voxOffset: 0,
            formatLabel: "DICOM series (\(ordered.count) files)",
            datatypeOverride: datatypeOverride,
            scalingOverride: scalingOverride
        )
        let image = MIQImage(header: header, storage: storage, payloadOffset: 0)
        let info = anchor.technicalInfo(frames: ordered.count, notes: geometry.notes)
        return DICOMSeries(image: image, info: info, sliceCount: ordered.count)
    }

    // MARK: - Helpers

    /// Header-only parse; pixel pages of a memory-mapped file are not touched.
    private static func load(_ url: URL) -> DICOMImageDescriptor? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        var reader = DICOMReader(data: data)
        guard let file = try? reader.read(),
              let descriptor = try? DICOMImageDescriptor(file: file),
              (try? descriptor.checkPixelDataSize()) != nil else { return nil }
        return descriptor
    }

    /// Cheap 132-byte probe so non-DICOM siblings are never mapped or parsed.
    private static func hasPart10Marker(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: DICOMReader.preambleLength + 4) else { return false }
        return DICOMReader.hasPart10Marker(prefix)
    }

    private static func compatible(
        _ slice: DICOMImageDescriptor,
        _ anchor: DICOMImageDescriptor,
        orientation: [Double]
    ) -> Bool {
        guard slice.frames == 1,
              slice.rows == anchor.rows, slice.columns == anchor.columns,
              slice.samplesPerPixel == anchor.samplesPerPixel,
              slice.bitsAllocated == anchor.bitsAllocated,
              slice.isSigned == anchor.isSigned,
              slice.datatype == anchor.datatype,
              slice.photometric == anchor.photometric,
              slice.framePositions?.count == 1,
              let o = slice.orientation else { return false }
        let rowDot = DICOMVector.dot(Array(o[0..<3]), Array(orientation[0..<3]))
        let colDot = DICOMVector.dot(Array(o[3..<6]), Array(orientation[3..<6]))
        return rowDot > 0.999 && colDot > 0.999
    }
}
