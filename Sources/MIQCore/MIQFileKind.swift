import Foundation

public enum MIQFileKind: Sendable, CaseIterable {
    case nii
    case niiGz
    case mgh
    case mgz
    case mif
    case mifGz
    case nrrd
    /// Detached NRRD header (`.nhdr`): text only, its `data file:` field names the
    /// payload file(s) next to it. See `MIQParser.resolveDetachedDataFile`.
    case nhdr
    /// MRtrix detached header (`.mih`): `file: <name> <offset>` names the payload.
    case mih
    /// ITK MetaImage with the payload attached after the header (`.mha`,
    /// `ElementDataFile = LOCAL`).
    case mha
    /// ITK MetaImage detached header (`.mhd`): `ElementDataFile` names the payload.
    case mhd
    /// Zarr directory store (`.zarr`, `.ome.zarr`, `.nii.zarr`); see `MIQParser.parseZarr`.
    case zarr
    /// DICOM Part-10 (`.dcm`/`.dicom`). Extensionless DICOM files are recognised by
    /// content via `MIQFileKind.sniffDICOM(url:)`.
    case dicom

    public init?(url: URL) {
        let path = url.path.lowercased()

        if path.hasSuffix(".nii.gz") { self = .niiGz; return }
        if path.hasSuffix(".mgh.gz") { self = .mgz; return }
        if path.hasSuffix(".mif.gz") { self = .mifGz; return }
        if path.hasSuffix(".zarr") { self = .zarr; return }

        switch url.pathExtension.lowercased() {
        case "nii": self = .nii
        case "mgh": self = .mgh
        case "mgz": self = .mgz
        case "mif": self = .mif
        case "nrrd": self = .nrrd
        case "nhdr": self = .nhdr
        case "mih": self = .mih
        case "mha": self = .mha
        case "mhd": self = .mhd
        case "dcm", "dicom": self = .dicom
        default: return nil
        }
    }

    public var isCompressed: Bool {
        switch self {
        case .niiGz, .mgz, .mifGz: return true
        case .nii, .mgh, .mif, .nrrd, .nhdr, .mih, .mha, .mhd, .zarr, .dicom: return false
        }
    }

    /// Whether the header names its payload in a separate file (resolved next to
    /// the header, see `MIQParser.resolveDetachedDataFile`). `.nrrd` and `.mha`
    /// *may* also reference one, but conventionally carry the payload inline.
    public var isDetachedHeader: Bool {
        switch self {
        case .nhdr, .mih, .mhd: return true
        case .nii, .niiGz, .mgh, .mgz, .mif, .mifGz, .nrrd, .mha, .zarr, .dicom: return false
        }
    }

    /// Whether the header, not the extension, decides if the payload is
    /// compressed — so a preview may have to inflate it in full even though
    /// `isCompressed` is false (NRRD `encoding: gzip`, MetaImage `CompressedData`).
    public var payloadEncodingDecidedByHeader: Bool {
        switch self {
        case .nrrd, .nhdr, .mha, .mhd: return true
        case .nii, .niiGz, .mgh, .mgz, .mif, .mifGz, .mih, .zarr, .dicom: return false
        }
    }

    /// Whether a cold preview of this kind can be bounded to a volume-0 prefix on
    /// a network volume. Only canonical NIfTI qualifies (see
    /// `MIQParser.loadBoundedNiftiPrefix`); every other kind needs a full read,
    /// which is what the large-network preview gate defers.
    public var supportsBoundedNetworkRead: Bool {
        switch self {
        // Zarr reads only the coarsest pyramid level's chunks, never the whole store.
        case .nii, .niiGz, .zarr: return true
        case .mgh, .mgz, .mif, .mifGz, .nrrd, .nhdr, .mih, .mha, .mhd, .dicom: return false
        }
    }

    /// Whether the Finder thumbnail extension should decline this file (keeping
    /// the system icon) rather than parse it. A thumbnail is spawned per visible
    /// icon, so a folder of large 4D `.mif.gz`/`.mgz` would otherwise fully
    /// decompress one file per icon. Two independent reasons to decline:
    ///
    /// - **On-disk size.** Declines when rendering the centre slice would pull the
    ///   whole file: a non-boundable kind over `thresholdBytes` that is
    ///   compressed, is NRRD/MetaImage (the header, not the extension, decides
    ///   whether its payload is compressed — `payloadEncodingDecidedByHeader`),
    ///   or sits on a network volume. Local uncompressed
    ///   MGH/MIF are memory-mapped, so size costs them nothing. An unknown size
    ///   (`nil`) never declines on this ground.
    /// - **Decoded size.** `estimatedDecompressedBytes` (from a header-only
    ///   probe, see `MIQParser.parseHeaderOnly(url:maxBytes:)` and `estimatedThumbnailDecodeBytes`)
    ///   over `decompressedBudgetBytes` declines whenever the thumbnail would
    ///   materialize the payload in RAM — the same compressed / `.nrrd` / network
    ///   cases, now including canonical NIfTI's volume 0. Catches highly
    ///   compressible files that the on-disk threshold lets through (a 40 MB
    ///   `.mgz` can inflate to GBs). `nil` (not probed) never declines on this
    ///   ground, which keeps the size-only behaviour for existing callers.
    public func declinesThumbnail(
        fileSizeBytes: Int?,
        isLocal: Bool,
        thresholdBytes: Int,
        estimatedDecompressedBytes: Int? = nil,
        decompressedBudgetBytes: Int = MIQPayloadSizeEstimate.thumbnailDecompressedBudgetBytes
    ) -> Bool {
        let materializesPayload = isCompressed || payloadEncodingDecidedByHeader || !isLocal
        if materializesPayload, let estimatedDecompressedBytes,
           estimatedDecompressedBytes > decompressedBudgetBytes {
            return true
        }
        guard !supportsBoundedNetworkRead,
              let fileSizeBytes, fileSizeBytes > thresholdBytes else { return false }
        return materializesPayload
    }

    public var displayName: String {
        switch self {
        case .nii: return "NIfTI-1"
        case .niiGz: return "Compressed NIfTI-1"
        case .mgh: return "MGH"
        case .mgz: return "Compressed MGH"
        case .mif: return "MRtrix MIF"
        case .mifGz: return "Compressed MRtrix MIF"
        case .nrrd: return "NRRD"
        case .nhdr: return "NRRD (detached)"
        case .mih: return "MRtrix MIH"
        case .mha: return "MetaImage"
        case .mhd: return "MetaImage (detached)"
        case .zarr: return "OME-Zarr"
        case .dicom: return "DICOM"
        }
    }

    public var pathSuffixes: [String] {
        switch self {
        case .nii: return [".nii"]
        case .niiGz: return [".nii.gz"]
        case .mgh: return [".mgh"]
        case .mgz: return [".mgz", ".mgh.gz"]
        case .mif: return [".mif"]
        case .mifGz: return [".mif.gz"]
        case .nrrd: return [".nrrd"]
        case .nhdr: return [".nhdr"]
        case .mih: return [".mih"]
        case .mha: return [".mha"]
        case .mhd: return [".mhd"]
        case .zarr: return [".zarr", ".ome.zarr", ".nii.zarr"]
        case .dicom: return [".dcm", ".dicom"]
        }
    }
}
