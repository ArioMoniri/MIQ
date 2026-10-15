import Foundation

/// Memory gate in front of the Quick Look preview's cold (uncached) parse.
///
/// The cold parse materialises the decoded payload (volume 0 for canonical
/// NIfTI, the whole payload for every other kind) before anything is on screen.
/// A tiny crafted header — say a 1 KB `.mha` claiming 4096³ doubles — would
/// otherwise make the extension try to allocate hundreds of GB and be killed.
/// The gate probes the header only (`MIQParser.probeHeader`, ≤ 64 KB of prefix)
/// and declines files whose decoded size exceeds the budget, so normal files
/// pay one small read and keep the fast path.
public enum MIQColdPreviewGate {
    /// Largest decoded payload the cold preview parse may materialise. Same as
    /// the 4D expansion budget: past it the extension risks being jetsammed.
    public static let budgetBytes = MIQPayloadSizeEstimate.previewFullDecompressionBudgetBytes

    /// The status text shown instead of the preview. `bytes` nil means the
    /// header's extent doesn't even fit in an `Int`.
    public static func tooLargeMessage(bytes: Int?) -> String {
        if let bytes {
            return "Too large to preview in Quick Look (\(MIQPayloadSizeEstimate.gigabytesText(bytes)))"
        }
        return "Too large to preview in Quick Look"
    }

    /// The refusal message for a probed header, or nil when the cold parse may
    /// proceed.
    ///
    /// Uncompressed `.nii` and `.mgh` are memory-mapped rather than copied, so a
    /// *complete* file (its size on disk covers `voxOffset` + the payload) costs
    /// address space, not RAM, and is allowed whatever its size. A header
    /// promising more than the file holds gets no such pass. The header alone
    /// can't tell whether a MIF/NRRD/MetaImage payload is raw and single-file;
    /// `refusalMessage(url:…)` reads that from the header text and exempts those
    /// too.
    public static func refusalMessage(
        header: MIQHeader,
        kind: MIQFileKind,
        fileSizeBytes: Int?,
        budgetBytes: Int = MIQColdPreviewGate.budgetBytes
    ) -> String? {
        let layout: ColdPayloadLayout = (kind == .nii || kind == .mgh)
            ? .mapped(dataFile: nil, payloadOffset: max(0, header.voxOffset))
            : .materialized
        return refusalMessage(
            header: header,
            kind: kind,
            layout: layout,
            payloadFileSizeBytes: fileSizeBytes,
            isLocal: true,
            budgetBytes: budgetBytes
        )
    }

    /// Core decision. `payloadFileSizeBytes` is the size of the file that holds
    /// the payload (the header's own file, or a `.mapped` layout's data file).
    ///
    /// Only kinds that inflate (`.mgz`, `.mif.gz`, gzip NRRD, compressed
    /// MetaImage, MIF `bit`) or join several data files materialise the payload
    /// in RAM and are budgeted. A raw single-file payload is memory-mapped on a
    /// local volume and passes when the file is complete; on a network volume it
    /// is read into RAM in full, so it is budgeted too — except canonical NIfTI,
    /// whose network read is bounded to volume 0 (`loadBoundedNiftiPrefix`).
    static func refusalMessage(
        header: MIQHeader,
        kind: MIQFileKind,
        layout: ColdPayloadLayout,
        payloadFileSizeBytes: Int?,
        isLocal: Bool,
        budgetBytes: Int = MIQColdPreviewGate.budgetBytes
    ) -> String? {
        guard let bytes = kind.estimatedThumbnailDecodeBytes(header: header) else {
            return tooLargeMessage(bytes: nil)
        }
        guard bytes > budgetBytes else { return nil }
        if case .mapped(_, let payloadOffset) = layout,
           isLocal || kind == .nii,
           let payloadFileSizeBytes {
            let (needed, overflow) = max(0, payloadOffset ?? 0).addingReportingOverflow(bytes)
            if !overflow, payloadFileSizeBytes >= needed { return nil }
        }
        return tooLargeMessage(bytes: bytes)
    }

    /// Probes `url`'s header and applies the decision above, reading the
    /// payload layout (raw/compressed, attached/detached, one or several data
    /// files) from the header text. Returns nil (proceed) when the header can't
    /// be probed — DICOM, Zarr, a malformed header — or a single detached data
    /// file can't be resolved or sized, so the full parse reports its own error
    /// as before.
    public static func refusalMessage(
        url: URL,
        parser: MIQParser = MIQParser(),
        budgetBytes: Int = MIQColdPreviewGate.budgetBytes
    ) -> String? {
        guard let kind = MIQFileKind(url: url),
              let header = try? parser.probeHeader(url: url) else { return nil }
        let layout = (try? parser.coldPayloadLayout(url: url, kind: kind, header: header)) ?? .materialized
        let payloadFileSize: Int?
        if case .mapped(let dataFile?, _) = layout {
            guard let dataURL = try? parser.resolveDetachedDataFile(dataFile, relativeTo: url),
                  let size = fileSize(dataURL) else { return nil }
            payloadFileSize = size
        } else {
            payloadFileSize = fileSize(url)
        }
        return refusalMessage(
            header: header,
            kind: kind,
            layout: layout,
            payloadFileSizeBytes: payloadFileSize,
            isLocal: VolumeLocation.isLocal(url),
            budgetBytes: budgetBytes
        )
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}

/// How the full parse holds a file's payload, as far as the cold-preview memory
/// gate cares (see `MIQColdPreviewGate`).
enum ColdPayloadLayout: Equatable {
    /// Inflated, unpacked or joined from several files into a new buffer: costs RAM.
    case materialized
    /// Raw bytes sliced in place from one memory-mapped file — the header's own
    /// (`dataFile` nil) or one detached data file (the header's spelling,
    /// resolved by `resolveDetachedDataFile`). `payloadOffset` is where the
    /// payload starts (a lower bound when unknown skips precede it); nil means
    /// the payload is the file's tail (NRRD `byte skip: -1`, MetaImage
    /// `HeaderSize = -1`).
    case mapped(dataFile: String?, payloadOffset: Int?)
}

extension MIQParser {
    /// Reads the payload layout from `url`'s header prefix (never the payload).
    func coldPayloadLayout(url: URL, kind: MIQFileKind, header: MIQHeader) throws -> ColdPayloadLayout {
        switch kind {
        case .nii, .mgh:
            return .mapped(dataFile: nil, payloadOffset: max(0, header.voxOffset))
        case .niiGz, .mgz, .mifGz, .zarr, .dicom:
            return .materialized
        case .mif, .mih, .nrrd, .nhdr, .mha, .mhd:
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: Self.headerOnlyProbeBytes) ?? Data()
            switch kind {
            case .mif, .mih: return try mifColdPayloadLayout(from: prefix)
            case .nrrd, .nhdr: return try nrrdColdPayloadLayout(from: prefix)
            default: return try metaImageColdPayloadLayout(from: prefix)
            }
        }
    }
}
