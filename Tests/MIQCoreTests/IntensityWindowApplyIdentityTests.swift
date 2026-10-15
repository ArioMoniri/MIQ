import Foundation
import Testing
@testable import MIQCore

/// Pins the vectorised `IntensityWindow.apply` byte-identical to the scalar
/// `values.map` it replaced, copied verbatim below as the reference.
struct IntensityWindowApplyIdentityTests {

    /// The pre-optimisation implementation, verbatim. Do not "fix" it: it *is*
    /// the contract.
    private static func referenceApply(_ values: [Float], bounds: IntensityWindow.Bounds) -> [UInt8] {
        let width = bounds.high - bounds.low
        let range = width > 0 ? width : 1
        return values.map { value in
            guard value.isFinite else {
                return 0
            }

            let clipped = max(bounds.low, min(bounds.high, value))
            let unit = max(0, min(1, (clipped - bounds.low) / range))
            return UInt8((unit * 255).rounded())
        }
    }

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
        /// Any bit pattern at all: NaNs (incl. signalling/payload), ±Inf,
        /// subnormals, ±0, huge magnitudes.
        mutating func anyFloat() -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: next())) }
    }

    private func expectIdentical(_ values: [Float], _ bounds: IntensityWindow.Bounds, _ label: String) {
        let expected = Self.referenceApply(values, bounds: bounds)
        let actual = IntensityWindow.apply(values, bounds: bounds)
        #expect(actual.count == expected.count, "\(label): count")
        if let i = zip(actual, expected).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            Issue.record("\(label): index \(i) value \(values[i]) (bits \(String(values[i].bitPattern, radix: 16))) bounds [\(bounds.low), \(bounds.high)] → \(actual[i]), expected \(expected[i])")
        }
    }

    /// Bounds sets spanning ordinary, tiny, huge, negative, degenerate,
    /// inverted and non-finite windows.
    private static let boundsCases: [IntensityWindow.Bounds] = [
        .init(low: 0, high: 255),
        .init(low: 0, high: 1),
        .init(low: -1024, high: 3071),
        .init(low: -160, high: 240),
        .init(low: 1e-10, high: 3e-9),
        .init(low: -3e38, high: 3e38),
        .init(low: -1e30, high: 1e30),
        .init(low: 5, high: 5),
        .init(low: 10, high: -10),
        .init(low: -.infinity, high: .infinity),
        .init(low: 0, high: .infinity),
        .init(low: -.infinity, high: 0),
        .init(low: .nan, high: 100),
        .init(low: 0, high: .nan),
        .init(low: -0.0, high: 0.0),
        .init(low: 0.1, high: 0.7),
        .init(low: 17.3, high: 4096.9),
    ]

    @Test func matchesReferenceOnRandomValuesAcrossBounds() {
        var rng = SplitMix(state: 42)
        for (b, bounds) in Self.boundsCases.enumerated() {
            // Odd length so the scalar tail runs too.
            var values = [Float]()
            values.reserveCapacity(4099)
            let lo = bounds.low.isFinite ? bounds.low : -1000
            let hi = bounds.high.isFinite ? bounds.high : 1000
            let span = abs(hi - lo).isFinite && hi != lo ? abs(hi - lo) : 1
            for i in 0..<4099 {
                switch i % 5 {
                case 0: values.append(rng.anyFloat())
                default:
                    // In and around the window, where every grey level is hit.
                    values.append(min(lo, hi) - span * 0.25 + rng.unit() * span * 1.5)
                }
            }
            expectIdentical(values, bounds, "bounds case \(b)")
        }
    }

    @Test func matchesReferenceOnSpecialValues() {
        let specials: [Float] = [
            .nan, -.nan, .signalingNaN, .infinity, -.infinity, 0, -0.0,
            .leastNonzeroMagnitude, -.leastNonzeroMagnitude, .leastNormalMagnitude,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1, -1, 255, 256, -1024, 3071,
        ]
        for (b, bounds) in Self.boundsCases.enumerated() {
            // Repeat so specials land in every SIMD lane and in the tail.
            let values = (0..<(specials.count * 17)).map { specials[$0 % specials.count] }
            expectIdentical(values, bounds, "specials, bounds case \(b)")
        }
    }

    /// Exact half-levels and their float neighbours: the values where ties-to-even
    /// (what a naive vector conversion does) and ties-away (`rounded()`) differ.
    @Test func matchesReferenceAtRoundingTies() {
        var values = [Float]()
        for k in 0..<256 {
            let tie = Float(k) + 0.5
            values += [tie, tie.nextUp, tie.nextDown, Float(k), Float(k).nextUp, Float(k).nextDown]
        }
        values += [Float(0.5).nextDown, Float(0.5) - 0x1p-25, 0x1p-25, 0x1p-24]
        for bounds in [IntensityWindow.Bounds(low: 0, high: 255), .init(low: 0, high: 510), .init(low: -255, high: 255)] {
            expectIdentical(values, bounds, "ties [\(bounds.low), \(bounds.high)]")
        }
    }

    /// The vector rounding helper on its whole contract range, sampled densely:
    /// every 2⁻⁸ step in [0, 255] plus the neighbours of each step.
    @Test func roundingHelperMatchesRoundedOnItsRange() {
        var inputs: [Float] = [-0.0, 0, 255, Float(255).nextDown, 0.5, Float(0.5).nextDown, Float(0.5).nextUp]
        var step: Float = 0
        while step <= 255 {
            inputs += [step, step.nextUp, step.nextDown.magnitude]
            step += 1.0 / 256
        }
        var i = 0
        while i + 16 <= inputs.count {
            var v = SIMD16<Float>()
            for lane in 0..<16 { v[lane] = inputs[i + lane] }
            let got = IntensityWindow.levels(roundingHalfAway: v)
            for lane in 0..<16 where got[lane] != UInt32(v[lane].rounded()) {
                Issue.record("levels(\(v[lane])) = \(got[lane]), expected \(UInt32(v[lane].rounded()))")
            }
            i += 16
        }
    }

    @Test func handlesEmptyAndShortInputs() {
        let bounds = IntensityWindow.Bounds(low: 0, high: 10)
        #expect(IntensityWindow.apply([], bounds: bounds).isEmpty)
        for n in 1...40 {
            let values = (0..<n).map { Float($0) * 0.37 - 1 }
            expectIdentical(values, bounds, "length \(n)")
        }
    }

    /// A full 512² slice of realistic data, the size the preview renders.
    @Test func matchesReferenceOnFullSizeSlice() {
        var rng = SplitMix(state: 7)
        var values = (0..<(512 * 512)).map { _ in -1100 + rng.unit() * 4200 }
        for i in stride(from: 3, to: values.count, by: 997) { values[i] = .nan }
        expectIdentical(values, .init(low: -160, high: 240), "512² CT-like")
        expectIdentical(values, .init(low: -1024, high: 3071), "512² full range")
    }
}
