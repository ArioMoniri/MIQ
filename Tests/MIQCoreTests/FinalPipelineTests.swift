import Foundation
import Testing
@testable import MIQCore

// Tests for the final preview-pipeline workstream: 8-bit grey output, per-volume
// 4D reads, head-mask windowing, and the cache / render-supersede policies.

private func lcg(_ seed: inout UInt32) -> UInt32 {
    seed = seed &* 1_103_515_245 &+ 12345
    return seed >> 8
}

private func scratchURL(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("miq-final-pipeline-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

// MARK: - Gray8 vs RGBA

struct PreviewBitmapTests {
    private func noisyVolume() -> MIQVolume {
        var seed: UInt32 = 7
        let n = 20 * 16 * 12
        let values = (0..<n).map { _ in Float(lcg(&seed) % 4000) / 3.0 - 200 }
        return ModalityFixtures.floatVolume(width: 20, height: 16, depth: 12, values: values)
    }

    @Test func grayscaleSlicesTakeTheGrayPathWithIdenticalLevels() throws {
        let volume = noisyVolume()
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98)
        let preview = volume.centerPreview(volumeIndex: 0, maxDimension: 64, options: options)
        #expect(preview.slices.count == 3)
        for (_, slice) in preview.slices {
            let bitmap = try #require(slice.previewBitmap())
            guard case .gray(let gray) = bitmap else {
                Issue.record("grayscale slice did not take the gray path")
                continue
            }
            let rgba = try #require(slice.rgbaBitmap())
            #expect(gray.width == rgba.width && gray.height == rgba.height)
            // Every grey byte equals the R, G and B bytes of the RGBA pixel.
            let bytes = [UInt8](rgba.pixels)
            for i in 0..<(gray.width * gray.height) {
                let g = gray.pixels[gray.pixels.startIndex + i]
                #expect(bytes[i * 4] == g && bytes[i * 4 + 1] == g && bytes[i * 4 + 2] == g && bytes[i * 4 + 3] == 255)
            }
            #expect(PreviewCachePolicy.costBytes(of: bitmap) == gray.width * gray.height)
        }
    }

    @Test func colourSlicesFallBackToRGBA() throws {
        let slice = SliceImage.rgb(RGBImage(width: 2, height: 1, pixels: [1, 2, 3, 4, 5, 6]))
        let bitmap = try #require(slice.previewBitmap())
        guard case .rgba(let rgba) = bitmap else {
            Issue.record("RGB slice must use RGBA")
            return
        }
        #expect([UInt8](rgba.pixels) == [1, 2, 3, 255, 4, 5, 6, 255])
        #expect(PreviewCachePolicy.costBytes(of: bitmap) == 8)
        #expect(bitmap.width == 2 && bitmap.height == 1)
    }

    @Test func mismatchedBufferHasNoBitmap() {
        #expect(SliceImage.grayscale(GrayscaleImage(width: 3, height: 3, pixels: [1])).previewBitmap() == nil)
    }
}

// MARK: - Cache policy

struct CostBoundedCacheTests {
    @Test func countLimitEvictsLeastRecentlyUsed() {
        let cache = CostBoundedCache<String, Int>(countLimit: 3, totalCostLimit: 1000)
        cache.insert(1, forKey: "a", cost: 1)
        cache.insert(2, forKey: "b", cost: 1)
        cache.insert(3, forKey: "c", cost: 1)
        // Touch "a": "b" becomes the oldest.
        #expect(cache.value(forKey: "a") == 1)
        cache.insert(4, forKey: "d", cost: 1)
        #expect(cache.value(forKey: "b") == nil)
        #expect(cache.keysByRecency == ["c", "a", "d"])
        #expect(cache.count == 3)
    }

    @Test func costLimitEvictsUntilWithinBudget() {
        let cache = CostBoundedCache<String, Int>(countLimit: 10, totalCostLimit: 100)
        cache.insert(1, forKey: "a", cost: 40)
        cache.insert(2, forKey: "b", cost: 40)
        cache.insert(3, forKey: "c", cost: 50)   // 130 > 100: drops "a"
        #expect(cache.keysByRecency == ["b", "c"])
        #expect(cache.totalCost == 90)
        cache.insert(4, forKey: "d", cost: 100)  // only "d" fits
        #expect(cache.keysByRecency == ["d"])
        #expect(cache.totalCost == 100)
    }

    @Test func oversizedEntryIsRefusedAndEvictsNothing() {
        let cache = CostBoundedCache<String, Int>(countLimit: 10, totalCostLimit: 100)
        cache.insert(1, forKey: "a", cost: 60)
        #expect(cache.insert(2, forKey: "big", cost: 101) == false)
        #expect(cache.keysByRecency == ["a"])
        #expect(cache.totalCost == 60)
    }

    @Test func replacingAKeyUpdatesItsCost() {
        let cache = CostBoundedCache<String, Int>(countLimit: 10, totalCostLimit: 100)
        cache.insert(1, forKey: "a", cost: 60)
        cache.insert(2, forKey: "a", cost: 10)
        #expect(cache.totalCost == 10)
        #expect(cache.value(forKey: "a") == 2)
        cache.removeValue(forKey: "a")
        #expect(cache.totalCost == 0 && cache.count == 0)
    }

    @Test func memoryPressureClearEmptiesEverything() {
        let cache: CostBoundedCache<String, Int> = PreviewCachePolicy.makeCache()
        for i in 0..<5 { cache.insert(i, forKey: "k\(i)", cost: 1024) }
        cache.removeAll()
        #expect(cache.count == 0 && cache.totalCost == 0)
        #expect(cache.value(forKey: "k1") == nil)
        // Still usable afterwards.
        cache.insert(9, forKey: "x", cost: 1)
        #expect(cache.value(forKey: "x") == 9)
    }

    @Test func previewPolicyCostsAreRealByteSizes() {
        #expect(PreviewCachePolicy.costBytes(width: 512, height: 400, bytesPerPixel: 1) == 512 * 400)
        #expect(PreviewCachePolicy.costBytes(width: 512, height: 400, bytesPerPixel: 4) == 512 * 400 * 4)
        #expect(PreviewCachePolicy.costBytes(width: 0, height: 400, bytesPerPixel: 4) == 0)
        #expect(PreviewCachePolicy.costBytes(width: Int.max, height: 2, bytesPerPixel: 4) == Int.max)
        let gray = PreviewSliceBitmap.gray(Gray8Bitmap(width: 4, height: 2, pixels: Data(count: 8)))
        let rgba = PreviewSliceBitmap.rgba(RGBABitmap(width: 4, height: 2, pixels: Data(count: 32)))
        #expect(PreviewCachePolicy.bundleCost([gray, rgba, gray]) == 48)
        // Three 512² grey slices: 0.75 MiB, so 64 bundles would fit the cost cap
        // and the count limit binds instead.
        #expect(PreviewCachePolicy.countLimit * 3 * 512 * 512 < PreviewCachePolicy.totalCostLimitBytes)
    }
}

// MARK: - Render generation gate

struct RenderGenerationGateTests {
    @Test func currentTicketApplies() {
        let gate = RenderGenerationGate()
        let ticket = gate.ticket()
        #expect(gate.decision(for: ticket, cancelled: false) == .apply)
    }

    @Test func staleTicketAppliesPixelsOnly() {
        var gate = RenderGenerationGate()
        let ticket = gate.ticket()
        gate.advance()
        #expect(!gate.isCurrent(ticket))
        #expect(gate.decision(for: ticket, cancelled: false) == .applyPixelsOnly)
        #expect(gate.decision(for: gate.ticket(), cancelled: false) == .apply)
    }

    @Test func cancelledRenderIsDiscardedEvenWhenCurrent() {
        var gate = RenderGenerationGate()
        #expect(gate.decision(for: gate.ticket(), cancelled: true) == .discard)
        let old = gate.ticket()
        gate.advance()
        #expect(gate.decision(for: old, cancelled: true) == .discard)
    }

    @Test func generationWrapsWithoutTrapping() {
        var gate = RenderGenerationGate(current: Int.max)
        let ticket = gate.ticket()
        gate.advance()
        #expect(gate.current == Int.min)
        #expect(gate.decision(for: ticket, cancelled: false) == .applyPixelsOnly)
    }
}

// MARK: - Per-volume NIfTI reads

struct NiftiVolumeReaderTests {
    static let dims = [6, 5, 4, 7]
    static var voxelsPerVolume: Int { dims[0] * dims[1] * dims[2] }

    /// Volume t's voxel i holds `t * 1000 + i`.
    static func niiBytes() -> Data {
        let values = (0..<(voxelsPerVolume * dims[3])).map { i -> Float in
            Float((i / voxelsPerVolume) * 1000 + i % voxelsPerVolume)
        }
        return ModalityFixtures.niftiBytes(dims: dims, values: values)
    }

    static func write(_ data: Data, name: String) throws -> URL {
        let url = scratchURL(name)
        try data.write(to: url)
        return url
    }

    static func header(of nii: Data) throws -> MIQHeader {
        try MIQParser().parseNiftiHeader(from: nii)
    }

    static func expectVolume(_ volume: MIQVolume, t: Int) {
        #expect(volume.voxel(x: 0, y: 0, z: 0, t: 0) == Float(t * 1000))
        let last = voxelsPerVolume - 1
        #expect(volume.voxel(x: dims[0] - 1, y: dims[1] - 1, z: dims[2] - 1, t: 0) == Float(t * 1000 + last))
        #expect(volume.voxel(x: 2, y: 1, z: 3, t: 0) == Float(t * 1000 + (3 * dims[1] + 1) * dims[0] + 2))
    }

    @Test(arguments: [true, false])
    func uncompressedFirstMiddleLast(mapped: Bool) throws {
        let nii = Self.niiBytes()
        let url = try Self.write(nii, name: "series.nii")
        let reader = try NiftiVolumeReader(url: url, header: try Self.header(of: nii), compressed: false, mapLocalFile: mapped)
        #expect(reader.volumeCount == 7)
        #expect(reader.volumeBytes == Self.voxelsPerVolume * 4)
        for t in [0, 3, 6] {
            Self.expectVolume(try reader.volume(at: t), t: t)
        }
    }

    @Test func compressedFirstMiddleLastAndRewind() throws {
        let nii = Self.niiBytes()
        let url = try Self.write(try TestZlib.gzip(nii), name: "series.nii.gz")
        // A tiny cache so the rewind really re-inflates from the start.
        let reader = try NiftiVolumeReader(url: url, header: try Self.header(of: nii), compressed: true, cacheByteLimit: 1)
        for t in [0, 3, 6, 1, 6, 5] {
            Self.expectVolume(try reader.volume(at: t), t: t)
        }
    }

    @Test func compressedMatchesFullDecompression() throws {
        let nii = Self.niiBytes()
        let url = try Self.write(try TestZlib.gzip(nii), name: "series.nii.gz")
        let header = try Self.header(of: nii)
        let reader = try #require(try MIQParser().niftiVolumeReader(url: url, header: header, isLocal: true))
        #expect(reader.isCompressed)
        let bytes = reader.volumeBytes
        for t in 0..<7 {
            let start = header.voxOffset + t * bytes
            #expect(try reader.volumeData(at: t) == nii.subdata(in: start..<(start + bytes)))
        }
    }

    @Test func decodedVolumesAreCachedWithinTheByteCap() throws {
        let nii = Self.niiBytes()
        let url = try Self.write(try TestZlib.gzip(nii), name: "series.nii.gz")
        let header = try Self.header(of: nii)
        let reader = try NiftiVolumeReader(url: url, header: header, compressed: true, cacheByteLimit: 2 * Self.voxelsPerVolume * 4)
        _ = try reader.volumeData(at: 1)
        _ = try reader.volumeData(at: 2)
        _ = try reader.volumeData(at: 3)
        #expect(!reader.isCached(1))
        #expect(reader.isCached(2) && reader.isCached(3))
        reader.purgeCache()
        #expect(!reader.isCached(3))
    }

    @Test func outOfRangeVolumesThrow() throws {
        let nii = Self.niiBytes()
        let url = try Self.write(nii, name: "series.nii")
        let reader = try NiftiVolumeReader(url: url, header: try Self.header(of: nii), compressed: false)
        #expect(throws: MIQError.self) { try reader.volumeData(at: -1) }
        #expect(throws: MIQError.self) { try reader.volumeData(at: 7) }
    }

    @Test(arguments: [true, false])
    func truncatedFileThrowsForTheMissingVolume(compressed: Bool) throws {
        let nii = Self.niiBytes()
        let cut = nii.prefix(nii.count - 10)
        let url = try Self.write(compressed ? try TestZlib.gzip(Data(cut)) : Data(cut), name: compressed ? "cut.nii.gz" : "cut.nii")
        let reader = try NiftiVolumeReader(url: url, header: try Self.header(of: nii), compressed: compressed, mapLocalFile: false)
        Self.expectVolume(try reader.volume(at: 0), t: 0)
        #expect(throws: MIQError.self) { try reader.volumeData(at: 6) }
        // The reader recovers for volumes that do exist.
        Self.expectVolume(try reader.volume(at: 5), t: 5)
    }

    @Test(arguments: [true, false])
    func cancelledReadThrowsAndTheNextReadSucceeds(compressed: Bool) async throws {
        let nii = Self.niiBytes()
        let url = try Self.write(compressed ? try TestZlib.gzip(nii) : nii, name: compressed ? "c.nii.gz" : "c.nii")
        let reader = try NiftiVolumeReader(url: url, header: try Self.header(of: nii), compressed: compressed, mapLocalFile: false)
        let task = Task.detached { () -> Result<Data, Error> in
            // Spin until cancelled so the read starts in a cancelled task.
            while !Task.isCancelled { await Task.yield() }
            return Result { try reader.volumeData(at: 4) }
        }
        task.cancel()
        let result = await task.value
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!reader.isCached(4))
        Self.expectVolume(try reader.volume(at: 4), t: 4)
    }

    @Test func nonNiftiKindsAnd3DHaveNoReader() throws {
        let nii = Self.niiBytes()
        let header = try Self.header(of: nii)
        #expect(try MIQParser().niftiVolumeReader(url: URL(fileURLWithPath: "/tmp/x.mgz"), header: header, isLocal: true) == nil)
        let threeD = try MIQParser().parseNiftiHeader(from: ModalityFixtures.niftiBytes(dims: [2, 2, 2], values: Array(repeating: 0, count: 8)))
        #expect(try MIQParser().niftiVolumeReader(url: URL(fileURLWithPath: "/tmp/x.nii"), header: threeD, isLocal: true) == nil)
    }
}

// MARK: - Head-mask windowing

struct HeadMaskWindowTests {
    /// A 40³ float volume: a sphere ("head", 300…500) in noisy air (5…30, above
    /// the window's zero floor so it takes part in the unmasked percentiles).
    static func headInAir(volumes: Int = 1) -> MIQVolume {
        let n = 40
        var seed: UInt32 = 99
        var values: [Float] = []
        values.reserveCapacity(n * n * n * volumes)
        for _ in 0..<volumes {
            for z in 0..<n {
                for y in 0..<n {
                    for x in 0..<n {
                        let dx = Float(x) - 19.5, dy = Float(y) - 19.5, dz = Float(z) - 19.5
                        let inside = dx * dx + dy * dy + dz * dz < 13 * 13
                        let r = Float(lcg(&seed) % 1000) / 1000
                        values.append(inside ? 300 + r * 200 : 5 + r * 25)
                    }
                }
            }
        }
        return ModalityFixtures.floatVolume(width: n, height: n, depth: n, volumes: volumes, values: values)
    }

    @Test func maskedPredicateExcludesValues() throws {
        let values: [Float] = (0..<200).map { $0 < 100 ? 1 + Float($0) / 100 : 100 + Float($0) }
        let all = try #require(IntensityWindow.bounds(for: values, lowerPercentile: 2, upperPercentile: 98))
        let masked = try #require(IntensityWindow.bounds(for: values, lowerPercentile: 2, upperPercentile: 98, including: { $0 >= 100 }))
        #expect(all.low < 2)
        #expect(masked.low >= 200)
        // nil predicate is the unmasked call, bit for bit.
        let viaNil = try #require(IntensityWindow.bounds(for: values, lowerPercentile: 2, upperPercentile: 98, including: nil))
        #expect(viaNil.low == all.low && viaNil.high == all.high)
    }

    @Test func tooFewMaskedValuesFallsBackToTheUnmaskedWindow() throws {
        let values: [Float] = (0..<200).map { Float($0) + 1 }
        let all = try #require(IntensityWindow.bounds(for: values, lowerPercentile: 2, upperPercentile: 98))
        let masked = try #require(IntensityWindow.bounds(for: values, lowerPercentile: 2, upperPercentile: 98, including: { $0 < 10 }))
        #expect(masked.low == all.low && masked.high == all.high)
    }

    @Test func airExcludedRaisesTheLowerBound() throws {
        let volume = Self.headInAir()
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98)
        let mask = try #require(try volume.windowingHeadMask())
        let plain = try #require(volume.fixedCenterWindow(options: options))
        let masked = try #require(volume.fixedCenterWindow(options: options, headMask: mask))
        // Unmasked, the 2nd percentile lands in the air noise; masked, in the head.
        #expect(plain.low < 31)
        #expect(masked.low > 250)
        #expect(masked.high > 450 && masked.high <= 500)

        // The cold-preview and interactive entry points agree with it.
        let preview = volume.centerPreview(maxDimension: 64, options: options, headMask: mask)
        #expect(preview.windowBounds == masked)
        #expect(volume.centerInteractiveState(options: options, headMask: mask).windowBounds == masked)
        #expect(volume.centerInteractiveState(options: options).windowBounds == plain)
    }

    @Test func ineligibleVolumesHaveNoMask() throws {
        #expect(try Self.headInAir(volumes: 2).windowingHeadMask() == nil)
        #expect(!Self.headInAir(volumes: 2).isHeadMaskWindowCandidate)
        let header = MIQHeader(
            littleEndian: true, dimensions: [4, 4, 4], pixdim: [1, 1, 1, 1], datatype: .rgb24,
            voxOffset: 0, sclSlope: 0, sclInter: 0, qformCode: 0, sformCode: 0,
            srowX: [1, 0, 0, 0], srowY: [0, 1, 0, 0], srowZ: [0, 0, 1, 0]
        )
        let rgb = MIQVolume(image: MIQImage(header: header, storage: Data(count: 4 * 4 * 4 * 3), payloadOffset: 0))
        #expect(try rgb.windowingHeadMask() == nil)
        // Constant volume: no threshold, no mask.
        let flat = ModalityFixtures.floatVolume(width: 8, height: 8, depth: 8, values: Array(repeating: 7, count: 512))
        #expect(try flat.windowingHeadMask() == nil)
    }
}
