import Foundation
import Testing
@testable import MIQCore

/// Verifies MIQCore against the cross-platform conformance corpus in
/// `Tests/Fixtures/conformance/` (shared with MIQ-Win; the contract is in that
/// directory's README.md).
///
/// The corpus and every expected value are produced by
/// `scripts/dev/make_conformance_corpus.py`, which computes them independently of
/// MIQCore from the voxel arrays it writes. To change the corpus, edit that script
/// and re-run it; this suite then checks MIQCore agrees. When a case fails, run with
/// `MIQ_CONFORMANCE_DUMP=1` to print what MIQCore actually reports, in expected.json
/// shape, for diffing against the committed file.
///
/// Fixtures are located through `#filePath` rather than SwiftPM resources, so the
/// test target needs no `resources:` entry.
struct ConformanceCorpusTests {
    static let corpusDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // MIQCoreTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/conformance", isDirectory: true)

    struct Index: Decodable {
        let contractVersion: Int
        let cases: [String]
    }

    struct Expected: Decodable {
        struct Scaling: Decodable { let slope: Double; let inter: Double }
        struct Probe: Decodable { let x: Int; let y: Int; let z: Int; let t: Int; let value: Double }
        struct Slice: Decodable {
            let mode: String
            let plane: String
            let volume: Int
            let sliceAxis: Int
            let sliceIndex: Int
            let width: Int
            let height: Int
            let sha256: String
        }

        let contractVersion: Int
        let file: String
        let format: String
        let dims: [Int]
        let volumes: Int
        let spacing: [Double]
        let datatype: String
        let orientation: String
        let effectiveScaling: Scaling
        let probes: [Probe]
        let slices: [Slice]
        let pending: String?
    }

    static func loadIndex() throws -> Index {
        let data = try Data(contentsOf: corpusDirectory.appendingPathComponent("index.json"))
        return try JSONDecoder().decode(Index.self, from: data)
    }

    static func loadExpected(_ name: String) throws -> Expected {
        let url = corpusDirectory.appendingPathComponent(name).appendingPathComponent("expected.json")
        return try JSONDecoder().decode(Expected.self, from: Data(contentsOf: url))
    }

    /// Case names split by whether expected.json marks them as depending on
    /// not-yet-landed behaviour (`pending`). Evaluated once, when arguments are built.
    static let allCaseNames: [String] = (try? loadIndex().cases) ?? []
    static let activeCaseNames = allCaseNames.filter { (try? loadExpected($0).pending) ?? nil == nil }
    static let pendingCaseNames = allCaseNames.filter { (try? loadExpected($0).pending) ?? nil != nil }

    // MARK: - Tests

    @Test
    func corpusIsPresentAndCurrent() throws {
        let index = try Self.loadIndex()
        #expect(index.contractVersion == 1)
        #expect(index.cases.count >= 8)
        var total = 0
        for name in index.cases {
            let expected = try Self.loadExpected(name)
            #expect(expected.contractVersion == index.contractVersion, "\(name)")
            let dir = Self.corpusDirectory.appendingPathComponent(name)
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                total += (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)[.size] as? Int) ?? 0
            }
        }
        #expect(total < 200 * 1024, "corpus is \(total) bytes; keep it under 200 KB")
    }

    @Test(arguments: activeCaseNames)
    func conforms(_ name: String) throws {
        try Self.verify(name)
    }

    /// Cases whose expectation depends on behaviour another workstream is landing.
    // MARK: - Verification

    static func verify(_ name: String) throws {
        let expected = try loadExpected(name)
        let url = corpusDirectory.appendingPathComponent(name).appendingPathComponent(expected.file)
        let image = try MIQParser().parse(url: url, fullyDecompress: true)
        let volume = MIQVolume(image: image)
        let actual = Actual(volume: volume, expected: expected)

        if ProcessInfo.processInfo.environment["MIQ_CONFORMANCE_DUMP"] != nil {
            print("conformance \(name): \(actual.json())")
        }

        #expect(actual.dims == expected.dims, "\(name): dims")
        #expect(actual.volumes == expected.volumes, "\(name): volumes")
        #expect(actual.spacing.count == expected.spacing.count
                && zip(actual.spacing, expected.spacing).allSatisfy { abs($0 - $1) <= 1e-5 },
                "\(name): spacing \(actual.spacing) vs \(expected.spacing)")
        #expect(actual.datatype == expected.datatype, "\(name): datatype")
        #expect(actual.orientation == expected.orientation, "\(name): orientation")
        #expect(actual.slope == expected.effectiveScaling.slope && actual.inter == expected.effectiveScaling.inter,
                "\(name): scaling \(actual.slope),\(actual.inter)")
        for (probe, value) in zip(expected.probes, actual.probes) {
            #expect(Double(value) == probe.value, "\(name): voxel(\(probe.x),\(probe.y),\(probe.z),\(probe.t)) = \(value)")
        }
        for (slice, got) in zip(expected.slices, actual.slices) {
            let label = "\(name): \(slice.mode) \(slice.plane) vol \(slice.volume)"
            #expect(got.sliceAxis == slice.sliceAxis, "\(label): slice axis")
            #expect(got.sliceIndex == slice.sliceIndex, "\(label): slice index")
            #expect(got.width == slice.width && got.height == slice.height, "\(label): \(got.width)x\(got.height)")
            #expect(got.sha256 == slice.sha256, "\(label): sha256")
        }
    }

    /// What MIQCore reports for a corpus file, computed exactly as the contract
    /// defines each field.
    struct Actual {
        struct Slice { let mode: String; let plane: String; let volume: Int; let sliceAxis: Int; let sliceIndex: Int; let width: Int; let height: Int; let sha256: String }

        let dims: [Int]
        let volumes: Int
        let spacing: [Double]
        let datatype: String
        let orientation: String
        let slope: Double
        let inter: Double
        let probes: [Float]
        let slices: [Slice]

        init(volume: MIQVolume, expected: Expected) {
            let header = volume.image.header
            dims = [volume.width, volume.height, volume.depth]
            volumes = volume.volumes
            spacing = (1...3).map { Double(header.pixdim[safe: $0] ?? 1) }
            datatype = header.datatypeLabel ?? header.datatype.label
            orientation = volume.storageOrientationLabel() ?? "unknown"
            // `voxel()` applies `raw * slope + inter` only when slope != 0.
            slope = header.sclSlope == 0 ? 1 : Double(header.sclSlope)
            inter = header.sclSlope == 0 ? 0 : Double(header.sclInter)
            probes = expected.probes.map { volume.voxel(x: $0.x, y: $0.y, z: $0.z, t: $0.t) }
            slices = expected.slices.map { spec in
                let mode: ViewOrientation = spec.mode == "neurological" ? .neurological : .stored
                let plane = SlicePlane(rawValue: spec.plane) ?? .axial
                let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: mode)
                let geometry = volume.sliceGeometry(for: plane, options: options)
                let index = [volume.width, volume.height, volume.depth][geometry.sliceAxis] / 2
                let values = volume.sliceValues(plane: plane, index: index, volumeIndex: spec.volume, options: options) ?? []
                return Slice(mode: spec.mode, plane: spec.plane, volume: spec.volume, sliceAxis: geometry.sliceAxis,
                             sliceIndex: index, width: geometry.width, height: geometry.height,
                             sha256: SHA256.hex(ConformanceCorpusTests.canonicalBytes(values)))
            }
        }

        func json() -> String {
            let object: [String: Any] = [
                "dims": dims, "volumes": volumes, "spacing": spacing, "datatype": datatype,
                "orientation": orientation, "effectiveScaling": ["slope": slope, "inter": inter],
                "probes": probes.map(Double.init),
                "slices": slices.map {
                    ["mode": $0.mode, "plane": $0.plane, "volume": $0.volume, "sliceAxis": $0.sliceAxis,
                     "sliceIndex": $0.sliceIndex, "width": $0.width, "height": $0.height, "sha256": $0.sha256]
                },
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The contract's slice encoding: each value as an IEEE-754 float32,
    /// little-endian, row-major from the top-left pixel.
    static func canonicalBytes(_ values: [Float]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * 4)
        for value in values {
            let bits = value.bitPattern
            bytes += [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
        }
        return bytes
    }

    @Test
    func sha256MatchesKnownVectors() {
        #expect(SHA256.hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}

/// Minimal SHA-256 (FIPS 180-4) for the conformance hashes: CryptoKit is not
/// available on the Linux harness, and the inputs are a few KB.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ message: [UInt8]) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + 4 * i
                w[i] = UInt32(data[b]) << 24 | UInt32(data[b + 1]) << 16 | UInt32(data[b + 2]) << 8 | UInt32(data[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.map { word in
            let s = String(word, radix: 16)
            return String(repeating: "0", count: 8 - s.count) + s
        }.joined()
    }
}
