import Foundation

/// Percentile windowing for volumetric intensity data.
/// Maps a finite-valued float buffer to 8-bit grayscale.
enum IntensityWindow {
    struct Bounds: Sendable {
        let low: Float
        let high: Float
    }

    /// Magnitude at or below which a value counts as background for the preferred
    /// foreground subset (see `bounds`).
    static let nonZeroFloor: Float = 1e-6

    /// Derives window bounds from a pooled set of values. Pass voxels from one slice for
    /// per-slice windowing, or from multiple slices to get a window shared across them.
    /// Returns `nil` if no finite values are present.
    static func bounds(for values: [Float], lowerPercentile: Double, upperPercentile: Double) -> Bounds? {
        // One fused pass: collect finite values and the above-floor subset, track
        // finite min/max, and count exact non-zeros for the rare fallback tier.
        // Both buffers reserve `values.count` up front — the subset is usually the
        // bulk of a slice, so without it the array reallocs repeatedly as it grows
        // into the hundreds of thousands.
        var finiteValues = [Float]()
        finiteValues.reserveCapacity(values.count)
        var aboveFloorValues = [Float]()
        aboveFloorValues.reserveCapacity(values.count)
        var minV = Float.greatestFiniteMagnitude
        var maxV = -Float.greatestFiniteMagnitude
        var nonZeroCount = 0

        for value in values where value.isFinite {
            finiteValues.append(value)
            if value < minV { minV = value }
            if value > maxV { maxV = value }
            if value != 0 {
                nonZeroCount += 1
                if abs(value) > nonZeroFloor { aboveFloorValues.append(value) }
            }
        }

        guard !finiteValues.isEmpty else {
            return nil
        }

        // Window over the foreground when it's substantial; the /20 ratio keeps a
        // dim region from being rejected when most voxels are background.
        //
        // Two tiers, tried in order. The 1e-6 floor also drops near-zero
        // interpolation residue, and wins whenever it leaves enough voxels — every
        // ordinary image, bit-identical to before. Only when it doesn't (data in
        // tiny units: an SI-unit ADC map sits around 1e-9, *entirely* below the
        // floor) do exactly-non-zero values stand in, so such a map windows over its
        // tissue instead of over tissue plus background zeros. Deliberately not a
        // floor scaled by the data's maximum: one outlier voxel (1e30 from a failed
        // fit) would lift that above real tissue.
        let minimumSubset = max(64, finiteValues.count / 20)

        // Only four order statistics are ever read, so the buffer is *selected*
        // rather than sorted (quickselect, below). The k-th smallest of a multiset
        // is algorithm-independent, so this is bit-identical to a full sort, not
        // merely close — `IntensityWindowSortTests` pins that against an
        // `Array.sort()` reference. The chosen array is mutated in place.
        let lower: Float
        let upper: Float
        if aboveFloorValues.count >= minimumSubset {
            (lower, upper) = percentileBounds(&aboveFloorValues, lowerPercentile: lowerPercentile, upperPercentile: upperPercentile)
        } else if nonZeroCount >= minimumSubset {
            // Tiny-unit fallback — the only case that pays a second pass.
            var nonZeroValues = [Float]()
            nonZeroValues.reserveCapacity(nonZeroCount)
            for value in finiteValues where value != 0 {
                nonZeroValues.append(value)
            }
            (lower, upper) = percentileBounds(&nonZeroValues, lowerPercentile: lowerPercentile, upperPercentile: upperPercentile)
        } else {
            (lower, upper) = percentileBounds(&finiteValues, lowerPercentile: lowerPercentile, upperPercentile: upperPercentile)
        }
        let windowLow = lower < upper ? lower : minV
        let windowHigh = lower < upper ? upper : maxV
        return Bounds(low: windowLow, high: windowHigh)
    }

    /// Fewest finite in-mask values `bounds(for:…including:)` accepts before it
    /// ignores the mask: a mask that barely touches the pooled slices would
    /// otherwise derive the window from a handful of edge voxels.
    static let minimumMaskedValues = 64

    /// `bounds(for:lowerPercentile:upperPercentile:)` over only the elements whose
    /// index `including` accepts — e.g. voxels inside a head mask, so air around
    /// the head does not take part in the percentiles. `including == nil` is
    /// exactly the unmasked call. When fewer than `minimumMaskedValues` finite
    /// values pass the predicate the mask is ignored and the unmasked window is
    /// returned, so a mask that misses the sampled voxels never blacks out a view.
    static func bounds(
        for values: [Float],
        lowerPercentile: Double,
        upperPercentile: Double,
        including: ((Int) -> Bool)?
    ) -> Bounds? {
        guard let including else {
            return bounds(for: values, lowerPercentile: lowerPercentile, upperPercentile: upperPercentile)
        }
        var kept = [Float]()
        kept.reserveCapacity(values.count)
        var finiteKept = 0
        for index in values.indices where including(index) {
            let value = values[index]
            kept.append(value)
            if value.isFinite { finiteKept += 1 }
        }
        if finiteKept >= minimumMaskedValues,
           let masked = bounds(for: kept, lowerPercentile: lowerPercentile, upperPercentile: upperPercentile) {
            return masked
        }
        return bounds(for: values, lowerPercentile: lowerPercentile, upperPercentile: upperPercentile)
    }

    /// Applies precomputed window bounds to `values`, producing 8-bit grayscale.
    ///
    /// Per element this is exactly
    ///
    ///     guard value.isFinite else { 0 }
    ///     clipped = max(low, min(high, value))
    ///     unit    = max(0, min(1, (clipped - low) / range))
    ///     UInt8((unit * 255).rounded())          // ties away from zero
    ///
    /// and the output is byte-identical to that scalar formulation for *every*
    /// input, including NaN/±Inf voxels and non-finite or inverted bounds
    /// (`IntensityWindowApplyIdentityTests` pins it against a verbatim copy).
    ///
    /// The bulk runs 16 lanes at a time on Swift's portable `SIMD16<Float>`, which
    /// lowers to NEON / SSE / AVX. Every lane operation is chosen so it is the same
    /// IEEE-754 operation the scalar code performs, so no result can drift:
    ///  * `Swift.min(x, y)` is literally `y < x ? y : x` and `Swift.max(x, y)` is
    ///    `y >= x ? y : x`; both are reproduced with lane masks + `replacing`,
    ///    *not* `pointwiseMin`/`pointwiseMax`, whose NaN and signed-zero rules
    ///    (IEEE `minimum`/`maximum`) differ from the scalar functions.
    ///  * subtraction, division and multiplication are correctly rounded IEEE
    ///    operations in both forms; nothing is fused (Swift never contracts to
    ///    FMA) and the division is
    ///    a true division, not a multiply by a precomputed reciprocal.
    ///  * the final rounding is not `SIMD.rounded(_:)` (which lowers to one libm
    ///    call per lane and erased most of the gain) but `levels(roundingHalfAway:)`,
    ///    an exact integer-only reformulation of `rounded()` for this range —
    ///    see its comment for the proof.
    ///
    /// Accelerate/vDSP is deliberately not used: vDSP documents no accuracy for
    /// `vsdiv` (it may divide via a reciprocal), its float→integer conversions
    /// round ties to even (0.5 → 0, where `rounded()` gives 1), and `vclip`'s NaN
    /// behaviour is unspecified. Any of those would make output platform-dependent
    /// and invisible to the Linux test harness; this path is identical everywhere
    /// and the harness exercises exactly the code that ships.
    static func apply(_ values: [Float], bounds: Bounds) -> [UInt8] {
        // No absolute floor on the width: float data can legitimately span far less
        // than 1e-6 (ADC maps in SI units sit around 1e-9), and a floor squashed such
        // a window into one or two grey levels. A degenerate window (high <= low)
        // clips every value to `low`, so the numerator is 0 and any positive divisor
        // gives black; 1 just keeps the division finite.
        let low = bounds.low
        let high = bounds.high
        let width = high - low
        let range = width > 0 ? width : 1
        let count = values.count

        return [UInt8](unsafeUninitializedCapacity: count) { out, initialized in
            values.withUnsafeBufferPointer { src in
                guard let s = src.baseAddress, let o = out.baseAddress else { return }
                typealias V = SIMD16<Float>
                let lanes = V.scalarCount
                let lowV = V(repeating: low)
                let highV = V(repeating: high)
                let rangeV = V(repeating: range)
                let zeroV = V(repeating: 0)
                let oneV = V(repeating: 1)
                let scaleV = V(repeating: 255)
                let maxFiniteV = V(repeating: .greatestFiniteMagnitude)
                let minFiniteV = V(repeating: -.greatestFiniteMagnitude)
                let zeroBits = SIMD16<UInt32>(repeating: 0)

                var i = 0
                let vectorEnd = count - count % lanes
                while i < vectorEnd {
                    let x = UnsafeRawPointer(s + i).loadUnaligned(as: V.self)
                    // isFinite: both comparisons are false for NaN, one for ±Inf.
                    let finite = (x .>= minFiniteV) .& (x .<= maxFiniteV)
                    let upperClipped = highV.replacing(with: x, where: x .< highV)       // min(high, x)
                    let clipped = lowV.replacing(with: upperClipped, where: upperClipped .>= lowV) // max(low, ·)
                    let q = (clipped - lowV) / rangeV
                    let capped = oneV.replacing(with: q, where: q .< oneV)               // min(1, q)
                    let unit = zeroV.replacing(with: capped, where: capped .>= zeroV)    // max(0, ·)
                    // Non-finite lanes computed garbage above (harmlessly: lane
                    // arithmetic never traps); they are forced to 0 here.
                    let grey = zeroBits.replacing(
                        with: levels(roundingHalfAway: unit * scaleV),
                        where: finite
                    )
                    let narrowed = SIMD16<UInt8>(truncatingIfNeeded: grey)
                    UnsafeMutableRawPointer(o + i).storeBytes(of: narrowed, as: SIMD16<UInt8>.self)
                    i += lanes
                }
                // Scalar tail (< 16 elements): the reference formulation verbatim.
                while i < count {
                    let value = s[i]
                    if value.isFinite {
                        let clipped = max(low, min(high, value))
                        let unit = max(0, min(1, (clipped - low) / range))
                        o[i] = UInt8((unit * 255).rounded())
                    } else {
                        o[i] = 0
                    }
                    i += 1
                }
            }
            initialized = count
        }
    }

    /// `UInt32(s.rounded())` for every lane `s` in `[-0, 255]` — the only range
    /// `apply` produces (`unit` is clamped to [0, 1], possibly -0, then × 255) —
    /// without calling libm.
    ///
    /// Why it is exact (IEEE binary32, default round-to-nearest-even):
    ///  * `biased = s + 2²³` lies in [2²³, 2²⁴), where the float spacing is exactly
    ///    1, so the add rounds `s` to the nearest integer `r` (ties to even), and
    ///    `biased`'s low mantissa bits hold `r` (≤ 256, so 9 bits suffice).
    ///  * `nearestEven = biased - 2²³ = r` is exact (both operands are integers
    ///    below 2²⁴).
    ///  * `s - r` is exact too: `|s - r| ≤ 0.5`, and both are multiples of
    ///    `ulp(s)` when `s ≥ 1` (any integer below 2²⁴ is), or Sterbenz applies
    ///    when `s < 1` (`r ∈ {0, 1}`).
    ///  * ties-to-even and ties-away-from-zero differ only when `s` sits exactly
    ///    halfway and was rounded *down* to the even neighbour, i.e. precisely when
    ///    `s - r == 0.5` (for `s ≥ 0`; a tie rounded up already went away from
    ///    zero). Adding 1 in exactly that case gives `rounded()`'s answer.
    /// `-0` biases to `2²³` → 0, matching `UInt8((-0.0).rounded()) == 0`.
    ///
    /// Swift never reassociates or contracts floating-point arithmetic (no
    /// fast-math, no FMA contraction), so `(s + 2²³) - 2²³` cannot be folded back
    /// to `s`, nor `unit * 255 + 2²³` fused into one unrounded operation.
    @inline(__always)
    static func levels(roundingHalfAway s: SIMD16<Float>) -> SIMD16<UInt32> {
        let magic = SIMD16<Float>(repeating: 8_388_608) // 2²³
        let biased = s + magic
        let nearestEven = biased - magic
        let tieRoundedDown = (s - nearestEven) .== SIMD16<Float>(repeating: 0.5)
        let r = unsafeBitCast(biased, to: SIMD16<UInt32>.self) & SIMD16<UInt32>(repeating: 0x1FF)
        return r &+ SIMD16<UInt32>(repeating: 0).replacing(with: SIMD16<UInt32>(repeating: 1), where: tieRoundedDown)
    }

    // MARK: - Percentile selection

    /// The two array positions a percentile interpolates between, and the weight
    /// between them. Index arithmetic is shared by every path so they cannot drift.
    private struct PercentilePosition {
        let lowerIndex: Int
        let upperIndex: Int
        let fraction: Float
    }

    private static func position(count: Int, p: Float) -> PercentilePosition {
        let clamped = max(0, min(1, p))
        let position = clamped * Float(count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        return PercentilePosition(
            lowerIndex: lowerIndex,
            upperIndex: upperIndex,
            fraction: position - Float(lowerIndex)
        )
    }

    /// Resolves both percentiles of `buffer` in place. The buffer is left partially
    /// ordered (only the positions actually read are placed), which is all the
    /// percentile interpolation needs.
    private static func percentileBounds(
        _ buffer: inout [Float],
        lowerPercentile: Double,
        upperPercentile: Double
    ) -> (Float, Float) {
        guard !buffer.isEmpty else {
            return (0, 0)
        }

        let lowerPosition = position(count: buffer.count, p: Float(lowerPercentile) / 100.0)
        let upperPosition = position(count: buffer.count, p: Float(upperPercentile) / 100.0)

        return buffer.withUnsafeMutableBufferPointer { buf -> (Float, Float) in
            // Resolve the (at most four) needed indices in ascending order. After
            // `select` fixes index k over [start, n), every element below k is ≤
            // buf[k], so the next select only has to search above it — and buf[k]
            // itself is never disturbed again.
            var wanted = [
                lowerPosition.lowerIndex, lowerPosition.upperIndex,
                upperPosition.lowerIndex, upperPosition.upperIndex,
            ]
            wanted.sort()
            var start = 0
            for k in wanted {
                if k < start { continue }  // duplicate index, already placed
                select(buf, k: k, from: start)
                start = k + 1
            }
            return (value(at: lowerPosition, in: buf), value(at: upperPosition, in: buf))
        }
    }

    private static func value(at position: PercentilePosition, in buf: UnsafeMutableBufferPointer<Float>) -> Float {
        if position.lowerIndex == position.upperIndex {
            return buf[position.lowerIndex]
        }
        let fraction = position.fraction
        return buf[position.lowerIndex] * (1 - fraction) + buf[position.upperIndex] * fraction
    }

    /// Iterative Hoare quickselect: rearranges `buf[start...]` so `buf[k]` holds the
    /// k-th smallest element of the whole buffer, given that everything below `start`
    /// is already ≤ everything at or above it.
    ///
    /// The caller filters the buffer to finite values, so the scanning loops cannot
    /// run off the ends on a NaN comparison. Iterative, so a pathological pivot
    /// sequence costs time rather than stack.
    private static func select(_ buf: UnsafeMutableBufferPointer<Float>, k: Int, from start: Int) {
        var lo = start
        var hi = buf.count - 1
        while lo < hi {
            placePivot(buf, lo, hi)
            let pivot = buf[lo]
            var i = lo - 1
            var j = hi + 1
            while true {
                repeat { i += 1 } while buf[i] < pivot
                repeat { j -= 1 } while buf[j] > pivot
                if i >= j { break }
                buf.swapAt(i, j)
            }
            // Hoare's invariant with a pivot taken from buf[lo] guarantees
            // lo ≤ j < hi, so each iteration strictly shrinks the range.
            if k <= j {
                hi = j
            } else {
                lo = j + 1
            }
        }
    }

    /// Median-of-three, left at `buf[lo]` for the partition to use as its pivot.
    /// A first-element pivot degrades on sorted or constant input — the common
    /// shape here, where most of a slice is identical background.
    private static func placePivot(_ buf: UnsafeMutableBufferPointer<Float>, _ lo: Int, _ hi: Int) {
        let mid = lo + (hi - lo) / 2
        if buf[mid] < buf[lo] { buf.swapAt(mid, lo) }
        if buf[hi] < buf[lo] { buf.swapAt(hi, lo) }
        if buf[hi] < buf[mid] { buf.swapAt(hi, mid) }
        buf.swapAt(lo, mid)
    }
}
