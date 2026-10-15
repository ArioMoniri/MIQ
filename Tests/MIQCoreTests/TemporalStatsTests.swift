import Foundation
import Testing
@testable import MIQCore

struct TemporalStatsTests {
    /// 4×4×4 series; voxels with x ≥ 1 are "brain" = 100 ± 2 alternating (std 2,
    /// tSNR 50), x == 0 is constant background 0. `spike` adds `spikeSize` to
    /// every brain voxel of one volume.
    static func series(volumes: Int, spike: Int? = nil, spikeSize: Float = 50, jitter: Bool = false) -> MIQVolume {
        let n = 4
        var seed: UInt64 = 0x1234_5678
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int(seed >> 40) % 1000) / 1000 - 0.5
        }
        var values: [Float] = []
        values.reserveCapacity(n * n * n * volumes)
        for t in 0..<volumes {
            for _ in 0..<n { for _ in 0..<n { for x in 0..<n {
                guard x >= 1 else { values.append(0); continue }
                var v: Float = 100 + (t % 2 == 0 ? 2 : -2)
                if jitter { v += noise() }
                if t == spike { v += spikeSize }
                values.append(v)
            } } }
        }
        return ModalityFixtures.floatVolume(width: n, height: n, depth: n, volumes: volumes, values: values)
    }

    @Test func sampleIndicesAreEvenAndCapped() {
        #expect(TemporalStats.sampleIndices(volumeCount: 5, cap: 64) == [0, 1, 2, 3, 4])
        let s = TemporalStats.sampleIndices(volumeCount: 200, cap: 64)
        #expect(s.count == 64)
        #expect(s.first == 0 && s.last == 199)
        #expect(zip(s, s.dropFirst()).allSatisfy { $0 < $1 })
        #expect(TemporalStats.sampleIndices(volumeCount: 0) == [])
    }

    @Test func mapsHaveKnownMeanStdAndTSNR() throws {
        let vol = Self.series(volumes: 40)
        let maps = try #require(TemporalStats.maps(for: vol))
        #expect(maps.sampledVolumes.count == 40)
        let brain = 1  // (x=1, y=0, z=0)
        #expect(abs(maps.mean[brain] - 100) < 1e-4)
        #expect(abs(maps.standardDeviation[brain] - 2) < 1e-4)
        #expect(abs(maps.tsnr[brain] - 50) < 1e-2)
        #expect(maps.tsnr[0] == 0)  // constant background: std guard
        #expect(maps.standardDeviation[0] == 0)
    }

    /// Large offset + small variance: Welford in Double keeps the std.
    @Test func noCancellationWithLargeMean() throws {
        var values: [Float] = []
        for t in 0..<10 { values.append(100_000 + (t % 2 == 0 ? 0.5 : -0.5)) }
        let vol = ModalityFixtures.floatVolume(width: 1, height: 1, depth: 1, volumes: 10, values: values)
        let maps = try #require(TemporalStats.maps(for: vol))
        #expect(abs(maps.standardDeviation[0] - 0.5) < 1e-3)
    }

    @Test func subsampledMapsStillAccurate() throws {
        let vol = Self.series(volumes: 130)
        let maps = try #require(TemporalStats.maps(for: vol, maxVolumes: 16))
        #expect(maps.sampledVolumes.count <= 16)
        // Sampled indices are a mix of even/odd volumes, so mean stays near 100.
        #expect(abs(maps.mean[1] - 100) < 1)
    }

    @Test func summaryFindsInjectedSpike() throws {
        let vol = Self.series(volumes: 40, spike: 20, jitter: true)
        let summary = try #require(TemporalStats.summary(for: vol))
        #expect(summary.volumeCount == 40)
        #expect(summary.framewiseDifference.count == 39)
        #expect(summary.spikeFrames == [20])
        #expect(summary.highDifferenceTransitions == [20, 21])
        // Foreground = the 48 brain voxels; background zeros excluded.
        #expect(summary.foregroundVoxelCount == 48)
        let tsnr = try #require(summary.medianTSNR)
        #expect(tsnr > 5 && tsnr < 50)
    }

    @Test func cleanSeriesHasNoSpikesAndTSNR50() throws {
        let vol = Self.series(volumes: 30)
        let summary = try #require(TemporalStats.summary(for: vol))
        #expect(summary.spikeCount == 0)
        #expect(abs((summary.medianTSNR ?? 0) - 50) < 0.1)
    }

    @Test func spikeAtSeriesEdge() {
        var trace = [Float](repeating: 1, count: 20)
        trace[0] = 30  // only 0→1 high, 1→2 normal → volume 0 is the outlier
        #expect(TemporalStats.spikes(in: trace).spikes == [0])
        trace[0] = 1
        trace[19] = 30
        #expect(TemporalStats.spikes(in: trace).spikes == [20])
    }

    @Test func degenerateInputsReturnNil() {
        let single = ModalityFixtures.floatVolume(width: 2, height: 2, depth: 1, values: [1, 2, 3, 4])
        #expect(TemporalStats.maps(for: single) == nil)
        #expect(TemporalStats.framewiseDifference(for: single) == nil)
        #expect(TemporalStats.maps(for: Self.series(volumes: 5), isCancelled: { true }) == nil)
    }

    @Test func traceSpatialSubsampleIsBounded() throws {
        let vol = Self.series(volumes: 4)
        let full = try #require(TemporalStats.framewiseDifference(for: vol))
        let coarse = try #require(TemporalStats.framewiseDifference(for: vol, maxVoxels: 8))
        #expect(full.count == 3 && coarse.count == 3)
        // ±2 alternation over brain voxels: |Δ| = 4 everywhere in brain.
        #expect(full.allSatisfy { $0 > 0 })
    }

    @Test func tsnrMapAsVolume() throws {
        let vol = Self.series(volumes: 10)
        let maps = try #require(TemporalStats.maps(for: vol))
        let tsnr = try #require(maps.volume(.tsnr, onGridOf: vol))
        #expect(tsnr.volumes == 1)
        #expect(abs(tsnr.voxel(x: 2, y: 3, z: 1) - 50) < 0.01)
    }
}
