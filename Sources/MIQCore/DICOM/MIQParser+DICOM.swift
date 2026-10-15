import Foundation

extension MIQParser {

    // MARK: - Public entry points

    /// Parses a DICOM Part-10 file into an image plus its display-safe technical
    /// summary. `parse(url:)` returns the same image for `.dicom` files; call this
    /// variant when the caller also wants the DICOM-specific metadata rows
    /// (`DICOMTechnicalInfo.displayEntries`).
    ///
    /// Supports uncompressed implicit / explicit VR little endian, 8/16/32-bit
    /// grayscale (MONOCHROME1/2) and 8-bit RGB, single- and multi-frame. Throws
    /// `MIQError.unsupportedFeature` with a presentable reason for compressed or
    /// big-endian transfer syntaxes ("Compressed DICOM (JPEG 2000) isn't supported yet").
    public func parseDICOM(url: URL) throws -> (image: MIQImage, info: DICOMTechnicalInfo) {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decodeDicom(data)
    }

    // MARK: - Internal

    func parseDicom(_ data: Data) throws -> MIQImage {
        try decodeDicom(data).image
    }

    func decodeDicom(_ data: Data) throws -> (image: MIQImage, info: DICOMTechnicalInfo) {
        var reader = DICOMReader(data: data)
        let descriptor = try DICOMImageDescriptor(file: reader.read())
        try validateDimensionExtent(
            [descriptor.columns, descriptor.rows, descriptor.frames, descriptor.samplesPerPixel],
            bytesPerVoxel: descriptor.bytesPerSample
        )
        try descriptor.checkPixelDataSize()

        let geometry = DICOMGeometry(
            columns: descriptor.columns,
            frames: descriptor.frames,
            pixelSpacing: descriptor.pixelSpacing,
            orientation: descriptor.orientation,
            framePositions: descriptor.framePositions,
            fallbackSliceSpacing: descriptor.spacingBetweenSlices ?? descriptor.sliceThickness
        )
        var (storage, offset) = descriptor.pixelStorage()
        var datatypeOverride: MIQDatatype?
        var scalingOverride: (slope: Float, inter: Float)?
        if let frameRescale = descriptor.frameRescale {
            // Enhanced multi-frame whose frames disagree on rescale: materialise
            // real-world values as float32, as `DICOMSeriesAssembler` does for slices.
            storage = descriptor.realWorldFloats(storage, offset: offset, rescale: frameRescale)
            offset = 0
            datatypeOverride = .float32
            scalingOverride = (0, 0)
        }
        let header = descriptor.header(
            frames: descriptor.frames,
            geometry: geometry,
            voxOffset: offset,
            formatLabel: descriptor.frames > 1 ? "DICOM (multi-frame)" : "DICOM",
            datatypeOverride: datatypeOverride,
            scalingOverride: scalingOverride
        )
        let image = MIQImage(header: header, storage: storage, payloadOffset: offset)
        return (image, descriptor.technicalInfo(frames: descriptor.frames, notes: geometry.notes))
    }
}

// MARK: - Descriptor

/// The pixel-format and geometry fields of one parsed DICOM file, validated.
struct DICOMImageDescriptor: Sendable {
    let file: DICOMParsedFile
    let rows: Int
    let columns: Int
    let frames: Int
    let samplesPerPixel: Int
    let bitsAllocated: Int
    let bitsStored: Int
    let isSigned: Bool
    let isPlanar: Bool
    let photometric: String
    let datatype: MIQDatatype
    /// Rescale of the first frame (or the only one) — the Pixel Value
    /// Transformation at the top level, in the shared group, or frame 1's.
    let rescaleSlope: Double
    let rescaleIntercept: Double
    /// Per-frame rescale for an enhanced multi-frame object whose Per-Frame
    /// Functional Groups give frames *different* Pixel Value Transformations;
    /// `nil` when every frame shares `rescaleSlope`/`rescaleIntercept`.
    let frameRescale: [DICOMRescale]?
    /// Six direction cosines (row, column) in LPS, or `nil` when absent/degenerate.
    let orientation: [Double]?
    /// One LPS position per frame, when every frame has one.
    let framePositions: [[Double]]?
    /// `[row spacing, column spacing]` mm.
    let pixelSpacing: [Double]?
    let sliceThickness: Double?
    let spacingBetweenSlices: Double?
    /// Internal grouping key; redacted in every textual form.
    let seriesUID: DICOMRedactedUID?
    let pixelRange: Range<Int>?

    var bytesPerSample: Int { bitsAllocated / 8 }
    var frameSamples: Int { rows * columns * samplesPerPixel }
    var frameBytes: Int { frameSamples * bytesPerSample }

    init(file: DICOMParsedFile) throws {
        self.file = file
        let data = file.data
        let top = file.dataset
        let shared = top.item(.sharedFunctionalGroups)
        let perFrame = top.sequences[.perFrameFunctionalGroups] ?? []
        let firstFrame = perFrame.first

        /// Looks `tag` up at the top level, then in the shared and first per-frame
        /// functional group's `sequence` item (enhanced multi-frame objects).
        func functional(_ tag: DICOMTag, _ sequence: DICOMTag) -> [Double]? {
            DICOMValues.decimals(tag, in: top, data: data)
                ?? DICOMValues.decimals(tag, in: shared?.item(sequence), data: data)
                ?? DICOMValues.decimals(tag, in: firstFrame?.item(sequence), data: data)
        }
        func us(_ tag: DICOMTag) -> Int? { DICOMValues.uint16(tag, in: top, data: data) }

        guard let rows = us(.rows), let columns = us(.columns), rows > 0, columns > 0 else {
            throw MIQError.invalidDimensions
        }
        let frames = DICOMValues.integer(.numberOfFrames, in: top, data: data) ?? 1
        guard frames >= 1 else { throw MIQError.invalidDimensions }

        let samplesPerPixel = us(.samplesPerPixel) ?? 1
        let bitsAllocated = us(.bitsAllocated) ?? 0
        guard [8, 16, 32].contains(bitsAllocated) else {
            throw MIQError.unsupportedFeature("DICOM with \(bitsAllocated) bits allocated per pixel isn't supported")
        }
        let bitsStored = us(.bitsStored) ?? bitsAllocated
        guard bitsStored >= 1, bitsStored <= bitsAllocated else {
            throw MIQError.malformedFile("DICOM Bits Stored exceeds Bits Allocated")
        }
        if let highBit = us(.highBit), highBit != bitsStored - 1 {
            throw MIQError.unsupportedFeature("DICOM pixel data with High Bit \(highBit) for \(bitsStored) stored bits isn't supported")
        }
        let isSigned = (us(.pixelRepresentation) ?? 0) == 1
        let photometric = DICOMTechnicalInfo.sanitizedCode(
            DICOMValues.string(.photometricInterpretation, in: top, data: data)
        )?.uppercased() ?? (samplesPerPixel == 3 ? "RGB" : "MONOCHROME2")

        let datatype: MIQDatatype
        switch (samplesPerPixel, photometric) {
        case (1, "MONOCHROME1"), (1, "MONOCHROME2"):
            switch (bitsAllocated, isSigned) {
            case (8, false): datatype = .uint8
            case (8, true): datatype = .int8
            case (16, false): datatype = .uint16
            case (16, true): datatype = .int16
            case (32, false): datatype = .uint32
            default: datatype = .int32
            }
        case (3, "RGB") where bitsAllocated == 8:
            datatype = .rgb24
        case (1, "PALETTE COLOR"):
            throw MIQError.unsupportedFeature("Palette-color DICOM isn't supported yet")
        case (3, _):
            throw MIQError.unsupportedFeature("DICOM color images other than 8-bit RGB aren't supported yet")
        default:
            throw MIQError.unsupportedFeature("DICOM with \(samplesPerPixel) samples per pixel isn't supported")
        }

        var slope = functional(.rescaleSlope, .pixelValueTransformationSequence)?.first ?? 1
        if slope == 0 { slope = 1 }
        let intercept = functional(.rescaleIntercept, .pixelValueTransformationSequence)?.first ?? 0

        // Enhanced objects may carry the Pixel Value Transformation per frame; a
        // frame without its own falls back to the value resolved above.
        var frameRescale: [DICOMRescale]?
        if frames > 1, perFrame.count == frames, samplesPerPixel == 1 {
            let perFrameRescale = perFrame.map { item -> DICOMRescale in
                let transform = item.item(.pixelValueTransformationSequence)
                var s = DICOMValues.decimals(.rescaleSlope, in: transform, data: data)?.first ?? slope
                if s == 0 || !s.isFinite { s = slope }
                var i = DICOMValues.decimals(.rescaleIntercept, in: transform, data: data)?.first ?? intercept
                if !i.isFinite { i = intercept }
                return DICOMRescale(slope: s, intercept: i)
            }
            if perFrameRescale.contains(where: { $0 != DICOMRescale(slope: slope, intercept: intercept) }) {
                frameRescale = perFrameRescale
            }
        }

        var orientation: [Double]?
        if let iop = functional(.imageOrientationPatient, .planeOrientationSequence), iop.count >= 6 {
            orientation = Self.normalizedOrientation(Array(iop.prefix(6)))
        }

        var positions: [[Double]]?
        if perFrame.count == frames {
            let perFramePositions = perFrame.compactMap { item -> [Double]? in
                guard let p = DICOMValues.decimals(.imagePositionPatient, in: item.item(.planePositionSequence), data: data),
                      p.count >= 3 else { return nil }
                return Array(p.prefix(3))
            }
            if perFramePositions.count == frames { positions = perFramePositions }
        }
        if positions == nil, frames == 1,
           let p = functional(.imagePositionPatient, .planePositionSequence), p.count >= 3 {
            positions = [Array(p.prefix(3))]
        }

        var pixelSpacing: [Double]?
        if let ps = functional(.pixelSpacing, .pixelMeasuresSequence), ps.count >= 2,
           ps[0] > 0, ps[1] > 0 {
            pixelSpacing = [ps[0], ps[1]]
        }

        let uid = DICOMValues.string(.seriesInstanceUID, in: top, data: data)

        self.rows = rows
        self.columns = columns
        self.frames = frames
        self.samplesPerPixel = samplesPerPixel
        self.bitsAllocated = bitsAllocated
        self.bitsStored = datatype == .rgb24 ? 8 : bitsStored
        self.isSigned = isSigned
        self.isPlanar = samplesPerPixel == 3 && (us(.planarConfiguration) ?? 0) == 1
        self.photometric = photometric
        self.datatype = datatype
        self.rescaleSlope = slope
        self.rescaleIntercept = intercept
        self.frameRescale = frameRescale
        self.orientation = orientation
        self.framePositions = positions
        self.pixelSpacing = pixelSpacing
        self.sliceThickness = Self.positive(functional(.sliceThickness, .pixelMeasuresSequence)?.first)
        self.spacingBetweenSlices = Self.positive(functional(.spacingBetweenSlices, .pixelMeasuresSequence)?.first)
        self.seriesUID = uid.map(DICOMRedactedUID.init)
        self.pixelRange = file.pixelData
    }

    /// Size sanity: the Pixel Data element (and therefore the file) must hold every
    /// declared sample. Call after `validateDimensionExtent` so the product can't overflow.
    func checkPixelDataSize() throws {
        guard let pixelRange else {
            throw MIQError.malformedFile("DICOM file has no pixel data")
        }
        let (total, overflow) = frameBytes.multipliedReportingOverflow(by: frames)
        guard !overflow, total > 0 else { throw MIQError.invalidDimensions }
        guard pixelRange.count >= total else { throw MIQError.truncatedData }
    }

    // MARK: Header

    /// Rescale as stored in `MIQHeader` (`MIQVolume` applies `raw × slope + inter`),
    /// exactly as the file states it, for every photometric interpretation: voxel
    /// values are the true modality values. MONOCHROME1 ("minimum is white") is
    /// handled at display time instead (`MIQHeader.invertsDisplay`). RGB has none.
    var headerScaling: (slope: Float, inter: Float) {
        if datatype == .rgb24 { return (0, 0) }
        let slope = Float(rescaleSlope)
        let inter = Float(rescaleIntercept)
        return slope.isFinite && inter.isFinite ? (slope, inter) : (1, 0)
    }

    /// Whether grayscale display should be inverted (MONOCHROME1).
    var invertsDisplay: Bool { photometric == "MONOCHROME1" }

    /// The sanitised Modality (0008,0060) code, if present.
    var modality: String? {
        DICOMTechnicalInfo.sanitizedCode(DICOMValues.string(.modality, in: file.dataset, data: file.data))
    }

    /// The whole payload as little-endian float32 real-world values, frame `f`
    /// rescaled with `rescale[f]` (grayscale only).
    func realWorldFloats(_ storage: Data, offset: Int, rescale: [DICOMRescale]) -> Data {
        let samples = frameSamples
        var floats = [Float]()
        floats.reserveCapacity(samples * frames)
        for f in 0..<frames {
            let r = rescale[safe: f] ?? DICOMRescale(slope: rescaleSlope, intercept: rescaleIntercept)
            for i in 0..<samples {
                let raw = rawSample(storage, offset: offset, index: f * samples + i)
                floats.append(Float(raw * r.slope + r.intercept))
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func header(
        frames: Int,
        geometry: DICOMGeometry,
        voxOffset: Int,
        formatLabel: String,
        datatypeOverride: MIQDatatype? = nil,
        scalingOverride: (slope: Float, inter: Float)? = nil
    ) -> MIQHeader {
        let scaling = scalingOverride ?? headerScaling
        let datatype = datatypeOverride ?? self.datatype
        let datatypeLabel: String? = datatypeOverride == nil && bitsStored < bitsAllocated
            ? "\(datatype.label) (\(bitsStored)-bit)"
            : nil
        var header = MIQHeader(
            littleEndian: true,
            dimensions: [columns, rows, frames, 1],
            pixdim: [1, geometry.pixdim.x, geometry.pixdim.y, geometry.pixdim.z],
            datatype: datatype,
            voxOffset: voxOffset,
            sclSlope: scaling.slope,
            sclInter: scaling.inter,
            qformCode: 0,
            sformCode: geometry.frame == nil ? 0 : 1,
            srowX: geometry.srowX,
            srowY: geometry.srowY,
            srowZ: geometry.srowZ,
            formatLabel: formatLabel,
            datatypeLabel: datatypeLabel,
            orientationFrame: geometry.frame
        )
        header.invertsDisplay = datatype != .rgb24 && invertsDisplay
        header.modality = modality
        return header
    }

    func technicalInfo(frames: Int, notes: [String]) -> DICOMTechnicalInfo {
        let data = file.data
        let top = file.dataset
        return DICOMTechnicalInfo(
            transferSyntaxName: file.transferSyntax.displayName,
            modality: DICOMTechnicalInfo.sanitizedCode(DICOMValues.string(.modality, in: top, data: data)),
            rows: rows,
            columns: columns,
            numberOfFrames: frames,
            samplesPerPixel: samplesPerPixel,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            photometricInterpretation: photometric,
            pixelSpacing: pixelSpacing,
            sliceThickness: sliceThickness,
            spacingBetweenSlices: spacingBetweenSlices,
            rescaleSlope: rescaleSlope,
            rescaleIntercept: rescaleIntercept,
            magneticFieldStrength: DICOMValues.decimal(.magneticFieldStrength, in: top, data: data),
            repetitionTime: DICOMValues.decimal(.repetitionTime, in: top, data: data),
            echoTime: DICOMValues.decimal(.echoTime, in: top, data: data),
            kvp: DICOMValues.decimal(.kvp, in: top, data: data),
            convolutionKernel: DICOMTechnicalInfo.sanitizedCode(DICOMValues.string(.convolutionKernel, in: top, data: data)),
            geometryNotes: notes
        )
    }

    // MARK: Pixels

    /// Storage + payload offset for the frames, zero-copy whenever the file's bytes
    /// are already in MIQ's layout. A copy is made only to interleave planar RGB or
    /// to clear/sign-extend the unused high bits when `BitsStored < BitsAllocated`
    /// and the file actually has stray bits there (overlay bits, unextended signs).
    func pixelStorage() -> (Data, Int) {
        guard let pixelRange else { return (Data(), 0) }
        let total = frameBytes * frames
        let data = file.data
        if isPlanar {
            return (Self.interleavePlanarRGB(data, start: pixelRange.lowerBound, rows: rows, columns: columns, frames: frames), 0)
        }
        if bitsStored < bitsAllocated,
           let fixed = Self.maskedSamples(
            data, start: pixelRange.lowerBound, count: total / bytesPerSample,
            bytesPerSample: bytesPerSample, bitsStored: bitsStored, signed: isSigned
           ) {
            return (fixed, 0)
        }
        return (data, pixelRange.lowerBound)
    }

    /// Returns a corrected copy when any sample has bits outside `bitsStored` that
    /// disagree with zero (unsigned) or sign extension (signed); `nil` when the
    /// stored bytes are already clean.
    static func maskedSamples(
        _ data: Data, start: Int, count: Int, bytesPerSample: Int, bitsStored: Int, signed: Bool
    ) -> Data? {
        let width = bytesPerSample * 8
        let widthMask: UInt64 = width >= 64 ? .max : (1 << UInt64(width)) - 1
        let storedMask: UInt64 = (1 << UInt64(bitsStored)) - 1
        let signBit: UInt64 = 1 << UInt64(bitsStored - 1)

        @inline(__always) func fixed(_ v: UInt64) -> UInt64 {
            let low = v & storedMask
            if signed, low & signBit != 0 {
                return (low | ~storedMask) & widthMask
            }
            return low
        }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            @inline(__always) func load(_ i: Int) -> UInt64 {
                let o = start + i * bytesPerSample
                var v: UInt64 = 0
                for b in 0..<bytesPerSample { v |= UInt64(raw[o + b]) << UInt64(8 * b) }
                return v
            }
            var firstBad = -1
            for i in 0..<count where fixed(load(i)) != load(i) {
                firstBad = i
                break
            }
            guard firstBad >= 0 else { return nil }
            var out = Data(count: count * bytesPerSample)
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                for i in 0..<count {
                    let v = fixed(load(i))
                    let o = i * bytesPerSample
                    for b in 0..<bytesPerSample { dst[o + b] = UInt8(truncatingIfNeeded: v >> UInt64(8 * b)) }
                }
            }
            return out
        }
    }

    /// Planar configuration 1 (`RRR…GGG…BBB…` per frame) → interleaved `RGBRGB…`.
    static func interleavePlanarRGB(_ data: Data, start: Int, rows: Int, columns: Int, frames: Int) -> Data {
        let plane = rows * columns
        var out = Data(count: plane * 3 * frames)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                for f in 0..<frames {
                    let frameBase = start + f * plane * 3
                    let outBase = f * plane * 3
                    for i in 0..<plane {
                        dst[outBase + i * 3] = src[frameBase + i]
                        dst[outBase + i * 3 + 1] = src[frameBase + plane + i]
                        dst[outBase + i * 3 + 2] = src[frameBase + 2 * plane + i]
                    }
                }
            }
        }
        return out
    }

    /// Raw sample `index` (of the whole pixel payload) as a Double. Used by the series
    /// assembler when slices disagree on rescale and must be materialised as float.
    func rawSample(_ storage: Data, offset: Int, index: Int) -> Double {
        let o = storage.startIndex + offset + index * bytesPerSample
        var v: UInt32 = 0
        for b in 0..<bytesPerSample { v |= UInt32(storage[o + b]) << UInt32(8 * b) }
        switch (bytesPerSample, isSigned) {
        case (1, true): return Double(Int8(truncatingIfNeeded: v))
        case (2, true): return Double(Int16(truncatingIfNeeded: v))
        case (4, true): return Double(Int32(bitPattern: v))
        default: return Double(v)
        }
    }

    // MARK: Helpers

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Normalises the row and column cosines; `nil` when either is zero-length or
    /// they are (nearly) parallel.
    static func normalizedOrientation(_ iop: [Double]) -> [Double]? {
        let r = DICOMVector.normalize(Array(iop[0..<3]))
        let c = DICOMVector.normalize(Array(iop[3..<6]))
        guard let r, let c else { return nil }
        let crossNorm = DICOMVector.norm(DICOMVector.cross(r, c))
        guard crossNorm > 0.5 else { return nil }
        return r + c
    }
}

/// One frame's Pixel Value Transformation (Rescale Slope / Intercept).
struct DICOMRescale: Sendable, Hashable {
    let slope: Double
    let intercept: Double
}

// MARK: - Geometry

/// Voxel→RAS affine for a stack of DICOM frames, mirroring the NRRD path's LPS→RAS
/// handling (negate the x and y world components).
///
/// Storage axes: x = column index (along the row cosine), y = row index (along the
/// column cosine), z = frame / slice. The slice vector is the mean step between
/// frame positions when every frame has one; otherwise the plane normal scaled by
/// `SpacingBetweenSlices` / `SliceThickness` (or 1 mm), recorded in `notes`.
struct DICOMGeometry: Sendable {
    let pixdim: (x: Float, y: Float, z: Float)
    let srowX: [Float]
    let srowY: [Float]
    let srowZ: [Float]
    let frame: OrientationFrame?
    let notes: [String]

    init(
        columns: Int,
        frames: Int,
        pixelSpacing: [Double]?,
        orientation: [Double]?,
        framePositions: [[Double]]?,
        fallbackSliceSpacing: Double?
    ) {
        var notes: [String] = []
        let colSpacing = pixelSpacing?[safe: 1] ?? 1
        let rowSpacing = pixelSpacing?[safe: 0] ?? 1
        if pixelSpacing == nil { notes.append("Pixel spacing missing; assuming 1 mm") }

        guard let orientation else {
            notes.append("Orientation unknown (no Image Orientation (Patient))")
            let z = fallbackSliceSpacing ?? 1
            if frames > 1, fallbackSliceSpacing == nil { notes.append("Slice spacing missing; assuming 1 mm") }
            pixdim = (Float(colSpacing), Float(rowSpacing), Float(z))
            srowX = [Float(colSpacing), 0, 0, 0]
            srowY = [0, Float(rowSpacing), 0, 0]
            srowZ = [0, 0, Float(z), 0]
            frame = nil
            self.notes = notes
            return
        }

        let r = Array(orientation[0..<3])
        let c = Array(orientation[3..<6])
        let n = DICOMVector.normalize(DICOMVector.cross(r, c)) ?? [0, 0, 1]

        var sliceVector: [Double]?
        if let positions = framePositions, positions.count == frames, frames > 1 {
            let first = positions[0], last = positions[frames - 1]
            let step = (0..<3).map { (last[$0] - first[$0]) / Double(frames - 1) }
            let stepLength = DICOMVector.norm(step)
            if stepLength > 1e-6 {
                sliceVector = step
                let irregular = (1..<frames).contains { i in
                    let d = (0..<3).map { positions[i][$0] - positions[i - 1][$0] }
                    return abs(DICOMVector.norm(d) - stepLength) > 0.1 * stepLength
                }
                if irregular { notes.append("Frame spacing is irregular; shown with the average spacing") }
            }
        }
        if sliceVector == nil {
            let spacing = fallbackSliceSpacing ?? 1
            sliceVector = n.map { $0 * spacing }
            if frames > 1 {
                notes.append(fallbackSliceSpacing == nil
                    ? "Frame positions unavailable; assuming 1 mm slices along the image normal"
                    : "Frame positions unavailable; slice spacing assumed from the header along the image normal")
            }
        }
        let z = sliceVector!
        let origin = framePositions?.first ?? [0, 0, 0]

        // LPS → RAS: negate x and y.
        srowX = [Float(-r[0] * colSpacing), Float(-c[0] * rowSpacing), Float(-z[0]), Float(-origin[0])]
        srowY = [Float(-r[1] * colSpacing), Float(-c[1] * rowSpacing), Float(-z[1]), Float(-origin[1])]
        srowZ = [Float(r[2] * colSpacing), Float(c[2] * rowSpacing), Float(z[2]), Float(origin[2])]
        pixdim = (Float(colSpacing), Float(rowSpacing), Float(DICOMVector.norm(z)))
        frame = OrientationFrame.from(srowX: srowX, srowY: srowY, srowZ: srowZ, source: .sform)
        self.notes = notes
    }
}

/// 3-vector helpers for DICOM patient-space geometry.
enum DICOMVector {
    static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    }

    static func norm(_ v: [Double]) -> Double {
        dot(v, v).squareRoot()
    }

    static func normalize(_ v: [Double]) -> [Double]? {
        let length = norm(v)
        guard length.isFinite, length > 1e-9 else { return nil }
        return v.map { $0 / length }
    }
}
