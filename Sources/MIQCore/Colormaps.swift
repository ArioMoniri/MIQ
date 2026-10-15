import Foundation

/// One premultiplication-free RGBA8 colour. Alpha 0 means "no overlay here".
public struct RGBA8: Sendable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let transparent = RGBA8(r: 0, g: 0, b: 0, a: 0)
}

/// Display colour maps for scalar data.
///
/// Every map is a 256-entry table indexed by a windowed 8-bit value (0 = window low,
/// 255 = window high). The perceptually uniform maps (`viridis`, `inferno`) are the
/// matplotlib tables by Nathaniel J. Smith, Stefan van der Walt and Eric Firing,
/// released under CC0 (https://github.com/BIDS/colormap); the values here are the
/// matplotlib `_cm_listed.py` floats rounded to 8 bits. `hot`, `cool` and `winter`
/// follow matplotlib's piecewise-linear definitions. `diverging` is a blue–white–red
/// map whose midpoint (entry 127.5, i.e. value 0 under `ScalarColorMapping.diverging`)
/// is white, for signed statistical maps.
public enum Colormap: String, Sendable, CaseIterable {
    case grayscale
    case hot
    case cool
    case winter
    case viridis
    case inferno
    case diverging

    /// True for maps meant for signed data centred on zero.
    public var isDiverging: Bool { self == .diverging }

    /// The 256-entry opaque table for this map. Built once per map and cached.
    public var table: [RGBA8] {
        switch self {
        case .grayscale: return ColormapTables.grayscale
        case .hot: return ColormapTables.hot
        case .cool: return ColormapTables.cool
        case .winter: return ColormapTables.winter
        case .viridis: return ColormapTables.viridis
        case .inferno: return ColormapTables.inferno
        case .diverging: return ColormapTables.diverging
        }
    }

    /// Colour for a windowed 8-bit value.
    public func color(_ index: UInt8) -> RGBA8 {
        table[Int(index)]
    }

    /// Colour for a normalised position in [0, 1] (clamped; NaN → entry 0).
    public func color(normalized t: Float) -> RGBA8 {
        table[Self.index(normalized: t)]
    }

    static func index(normalized t: Float) -> Int {
        guard t.isFinite else { return t == .infinity ? 255 : 0 }
        let clamped = min(max(t, 0), 1)
        return min(255, Int(clamped * 255 + 0.5))
    }

    /// Maps an already-windowed grayscale buffer (e.g. a `GrayscaleImage`'s pixels)
    /// through this map into interleaved, opaque RGBA bytes.
    public func rgba(fromWindowed pixels: [UInt8]) -> [UInt8] {
        let lut = table
        var out = [UInt8](repeating: 255, count: pixels.count * 4)
        var w = 0
        for p in pixels {
            let c = lut[Int(p)]
            out[w] = c.r
            out[w + 1] = c.g
            out[w + 2] = c.b
            w += 4
        }
        return out
    }

    // MARK: - Auto-suggestion

    /// NIfTI-1 `intent_code` values that denote statistics of signed, zero-centred
    /// distributions (correlation, t, z), shown with the diverging map.
    public static let signedStatisticIntentCodes: Set<Int> = [2, 3, 5]
    /// NIfTI-1 `intent_code` values for non-negative statistics (F, chi², beta,
    /// chi, gamma, Poisson, …, -log10 p), shown with `hot`.
    public static let positiveStatisticIntentCodes: Set<Int> = [4, 6, 7, 12, 13, 14, 15, 16, 21, 22, 23, 24]

    /// Suggests a colour map from what is known about the data.
    ///
    /// - `intentCode` (NIfTI `intent_code`, when available): z-score / t-test /
    ///   correlation → `.diverging`; F, χ² and other non-negative statistics → `.hot`.
    /// - Otherwise a floating-point volume whose range straddles zero roughly
    ///   symmetrically (the smaller tail is at least `symmetryRatio` of the larger)
    ///   → `.diverging`.
    /// - Everything else → `.grayscale`.
    public static func suggested(
        intentCode: Int?,
        minValue: Float,
        maxValue: Float,
        isFloatingPoint: Bool,
        symmetryRatio: Float = 0.25
    ) -> Colormap {
        if let intentCode {
            if signedStatisticIntentCodes.contains(intentCode) { return .diverging }
            if positiveStatisticIntentCodes.contains(intentCode) { return .hot }
        }
        guard isFloatingPoint, minValue.isFinite, maxValue.isFinite, minValue < 0, maxValue > 0 else {
            return .grayscale
        }
        let negative = -minValue
        let ratio = min(negative, maxValue) / max(negative, maxValue)
        return ratio >= symmetryRatio ? .diverging : .grayscale
    }
}

/// Maps raw scalar values (e.g. a statistical map slice) to RGBA with optional
/// thresholding, for use as an overlay or as a stand-alone coloured slice.
///
/// Sequential maps window `[low, high]` onto the table. Diverging maps are always
/// symmetric around zero: `limit` = max(|low|, |high|), so -limit → blue end,
/// 0 → white, +limit → red end.
///
/// `threshold`, when set, makes sub-threshold voxels transparent: for diverging
/// maps |v| < threshold (both tails survive), for sequential maps v < threshold.
/// Non-finite values are always transparent.
public struct ScalarColorMapping: Sendable, Hashable {
    public var colormap: Colormap
    public var low: Float
    public var high: Float
    public var threshold: Float?

    public init(colormap: Colormap, low: Float, high: Float, threshold: Float? = nil) {
        self.colormap = colormap
        self.low = low
        self.high = high
        self.threshold = threshold
    }

    /// Symmetric diverging mapping: `[-limit, +limit]`, |v| < `threshold` transparent.
    public static func diverging(limit: Float, threshold: Float? = nil) -> ScalarColorMapping {
        let l = abs(limit)
        return ScalarColorMapping(colormap: .diverging, low: -l, high: l, threshold: threshold)
    }

    /// Normalised table position for `value` (diverging: 0.5 at zero).
    public func normalizedPosition(_ value: Float) -> Float {
        if colormap.isDiverging {
            let limit = max(abs(low), abs(high))
            guard limit > 0, limit.isFinite else { return 0.5 }
            return 0.5 + 0.5 * value / limit
        }
        let span = high - low
        guard span > 0, span.isFinite else { return value >= high ? 1 : 0 }
        return (value - low) / span
    }

    /// True when `value` survives the threshold (and is finite).
    public func isVisible(_ value: Float) -> Bool {
        guard value.isFinite else { return false }
        guard let threshold else { return true }
        return colormap.isDiverging ? abs(value) >= threshold : value >= threshold
    }

    public func color(for value: Float) -> RGBA8 {
        guard isVisible(value) else { return .transparent }
        return colormap.color(normalized: normalizedPosition(value))
    }

    /// Colours a row-major scalar buffer into an RGBA bitmap; `nil` when
    /// `values.count != width * height` or the size is degenerate.
    public func rgbaBitmap(values: [Float], width: Int, height: Int) -> RGBABitmap? {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        let lut = colormap.table
        var out = [UInt8](repeating: 0, count: values.count * 4)
        var w = 0
        for v in values {
            if isVisible(v) {
                let c = lut[Colormap.index(normalized: normalizedPosition(v))]
                out[w] = c.r
                out[w + 1] = c.g
                out[w + 2] = c.b
                out[w + 3] = 255
            }
            w += 4
        }
        return RGBABitmap(width: width, height: height, pixels: Data(out))
    }
}

extension GrayscaleImage {
    /// Applies `colormap` to this already-windowed slice. `nil` when the pixel
    /// buffer doesn't match the declared size.
    public func rgbaBitmap(colormap: Colormap) -> RGBABitmap? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        return RGBABitmap(width: width, height: height, pixels: Data(colormap.rgba(fromWindowed: pixels)))
    }
}

// MARK: - Tables

enum ColormapTables {
    static let grayscale: [RGBA8] = (0..<256).map { i in
        let v = UInt8(i)
        return RGBA8(r: v, g: v, b: v)
    }

    /// matplotlib `hot`: red ramps 0.0416→1 over [0, 0.365], green 0→1 over
    /// [0.365, 0.746], blue 0→1 over [0.746, 1].
    static let hot: [RGBA8] = (0..<256).map { i in
        let t = Float(i) / 255
        let r = 0.0416 + (1 - 0.0416) * ramp(t, 0, 0.365079)
        let g = ramp(t, 0.365079, 0.746032)
        let b = ramp(t, 0.746032, 1)
        return RGBA8(r: u8(r), g: u8(g), b: u8(b))
    }

    /// matplotlib `cool`: (t, 1 - t, 1).
    static let cool: [RGBA8] = (0..<256).map { i in
        let t = Float(i) / 255
        return RGBA8(r: u8(t), g: u8(1 - t), b: 255)
    }

    /// matplotlib `winter`: (0, t, 1 - t/2).
    static let winter: [RGBA8] = (0..<256).map { i in
        let t = Float(i) / 255
        return RGBA8(r: 0, g: u8(t), b: u8(1 - 0.5 * t))
    }

    /// Blue (33, 102, 172) → white → red (178, 24, 43), linear in sRGB. Entries
    /// 127 and 128 straddle the white midpoint.
    static let diverging: [RGBA8] = (0..<256).map { i in
        let t = Float(i) / 255
        let blue: (Float, Float, Float) = (33, 102, 172)
        let red: (Float, Float, Float) = (178, 24, 43)
        let white: (Float, Float, Float) = (255, 255, 255)
        let (a, b, f): ((Float, Float, Float), (Float, Float, Float), Float) =
            t < 0.5 ? (blue, white, t / 0.5) : (white, red, (t - 0.5) / 0.5)
        func mix(_ x: Float, _ y: Float) -> UInt8 { UInt8(min(255, max(0, (x + (y - x) * f).rounded()))) }
        return RGBA8(r: mix(a.0, b.0), g: mix(a.1, b.1), b: mix(a.2, b.2))
    }

    static let viridis: [RGBA8] = unpack(viridisPacked)
    static let inferno: [RGBA8] = unpack(infernoPacked)

    private static func ramp(_ t: Float, _ a: Float, _ b: Float) -> Float {
        min(1, max(0, (t - a) / (b - a)))
    }

    private static func u8(_ v: Float) -> UInt8 {
        UInt8(min(255, max(0, (v * 255).rounded())))
    }

    private static func unpack(_ packed: [UInt32]) -> [RGBA8] {
        packed.map { RGBA8(r: UInt8(($0 >> 16) & 0xFF), g: UInt8(($0 >> 8) & 0xFF), b: UInt8($0 & 0xFF)) }
    }

    /// matplotlib `viridis` (CC0), 0xRRGGBB.
    static let viridisPacked: [UInt32] = [
        0x440154, 0x440256, 0x450457, 0x450559, 0x46075A, 0x46085C, 0x460A5D, 0x460B5E,
        0x470D60, 0x470E61, 0x471063, 0x471164, 0x471365, 0x481467, 0x481668, 0x481769,
        0x48186A, 0x481A6C, 0x481B6D, 0x481C6E, 0x481D6F, 0x481F70, 0x482071, 0x482173,
        0x482374, 0x482475, 0x482576, 0x482677, 0x482878, 0x482979, 0x472A7A, 0x472C7A,
        0x472D7B, 0x472E7C, 0x472F7D, 0x46307E, 0x46327E, 0x46337F, 0x463480, 0x453581,
        0x453781, 0x453882, 0x443983, 0x443A83, 0x443B84, 0x433D84, 0x433E85, 0x423F85,
        0x424086, 0x424186, 0x414287, 0x414487, 0x404588, 0x404688, 0x3F4788, 0x3F4889,
        0x3E4989, 0x3E4A89, 0x3E4C8A, 0x3D4D8A, 0x3D4E8A, 0x3C4F8A, 0x3C508B, 0x3B518B,
        0x3B528B, 0x3A538B, 0x3A548C, 0x39558C, 0x39568C, 0x38588C, 0x38598C, 0x375A8C,
        0x375B8D, 0x365C8D, 0x365D8D, 0x355E8D, 0x355F8D, 0x34608D, 0x34618D, 0x33628D,
        0x33638D, 0x32648E, 0x32658E, 0x31668E, 0x31678E, 0x31688E, 0x30698E, 0x306A8E,
        0x2F6B8E, 0x2F6C8E, 0x2E6D8E, 0x2E6E8E, 0x2E6F8E, 0x2D708E, 0x2D718E, 0x2C718E,
        0x2C728E, 0x2C738E, 0x2B748E, 0x2B758E, 0x2A768E, 0x2A778E, 0x2A788E, 0x29798E,
        0x297A8E, 0x297B8E, 0x287C8E, 0x287D8E, 0x277E8E, 0x277F8E, 0x27808E, 0x26818E,
        0x26828E, 0x26828E, 0x25838E, 0x25848E, 0x25858E, 0x24868E, 0x24878E, 0x23888E,
        0x23898E, 0x238A8D, 0x228B8D, 0x228C8D, 0x228D8D, 0x218E8D, 0x218F8D, 0x21908D,
        0x21918C, 0x20928C, 0x20928C, 0x20938C, 0x1F948C, 0x1F958B, 0x1F968B, 0x1F978B,
        0x1F988B, 0x1F998A, 0x1F9A8A, 0x1E9B8A, 0x1E9C89, 0x1E9D89, 0x1F9E89, 0x1F9F88,
        0x1FA088, 0x1FA188, 0x1FA187, 0x1FA287, 0x20A386, 0x20A486, 0x21A585, 0x21A685,
        0x22A785, 0x22A884, 0x23A983, 0x24AA83, 0x25AB82, 0x25AC82, 0x26AD81, 0x27AD81,
        0x28AE80, 0x29AF7F, 0x2AB07F, 0x2CB17E, 0x2DB27D, 0x2EB37C, 0x2FB47C, 0x31B57B,
        0x32B67A, 0x34B679, 0x35B779, 0x37B878, 0x38B977, 0x3ABA76, 0x3BBB75, 0x3DBC74,
        0x3FBC73, 0x40BD72, 0x42BE71, 0x44BF70, 0x46C06F, 0x48C16E, 0x4AC16D, 0x4CC26C,
        0x4EC36B, 0x50C46A, 0x52C569, 0x54C568, 0x56C667, 0x58C765, 0x5AC864, 0x5CC863,
        0x5EC962, 0x60CA60, 0x63CB5F, 0x65CB5E, 0x67CC5C, 0x69CD5B, 0x6CCD5A, 0x6ECE58,
        0x70CF57, 0x73D056, 0x75D054, 0x77D153, 0x7AD151, 0x7CD250, 0x7FD34E, 0x81D34D,
        0x84D44B, 0x86D549, 0x89D548, 0x8BD646, 0x8ED645, 0x90D743, 0x93D741, 0x95D840,
        0x98D83E, 0x9BD93C, 0x9DD93B, 0xA0DA39, 0xA2DA37, 0xA5DB36, 0xA8DB34, 0xAADC32,
        0xADDC30, 0xB0DD2F, 0xB2DD2D, 0xB5DE2B, 0xB8DE29, 0xBADE28, 0xBDDF26, 0xC0DF25,
        0xC2DF23, 0xC5E021, 0xC8E020, 0xCAE11F, 0xCDE11D, 0xD0E11C, 0xD2E21B, 0xD5E21A,
        0xD8E219, 0xDAE319, 0xDDE318, 0xDFE318, 0xE2E418, 0xE5E419, 0xE7E419, 0xEAE51A,
        0xECE51B, 0xEFE51C, 0xF1E51D, 0xF4E61E, 0xF6E620, 0xF8E621, 0xFBE723, 0xFDE725,
    ]

    /// matplotlib `inferno` (CC0), 0xRRGGBB.
    static let infernoPacked: [UInt32] = [
        0x000004, 0x010005, 0x010106, 0x010108, 0x02010A, 0x02020C, 0x02020E, 0x030210,
        0x040312, 0x040314, 0x050417, 0x060419, 0x07051B, 0x08051D, 0x09061F, 0x0A0722,
        0x0B0724, 0x0C0826, 0x0D0829, 0x0E092B, 0x10092D, 0x110A30, 0x120A32, 0x140B34,
        0x150B37, 0x160B39, 0x180C3C, 0x190C3E, 0x1B0C41, 0x1C0C43, 0x1E0C45, 0x1F0C48,
        0x210C4A, 0x230C4C, 0x240C4F, 0x260C51, 0x280B53, 0x290B55, 0x2B0B57, 0x2D0B59,
        0x2F0A5B, 0x310A5C, 0x320A5E, 0x340A5F, 0x360961, 0x380962, 0x390963, 0x3B0964,
        0x3D0965, 0x3E0966, 0x400A67, 0x420A68, 0x440A68, 0x450A69, 0x470B6A, 0x490B6A,
        0x4A0C6B, 0x4C0C6B, 0x4D0D6C, 0x4F0D6C, 0x510E6C, 0x520E6D, 0x540F6D, 0x550F6D,
        0x57106E, 0x59106E, 0x5A116E, 0x5C126E, 0x5D126E, 0x5F136E, 0x61136E, 0x62146E,
        0x64156E, 0x65156E, 0x67166E, 0x69166E, 0x6A176E, 0x6C186E, 0x6D186E, 0x6F196E,
        0x71196E, 0x721A6E, 0x741A6E, 0x751B6E, 0x771C6D, 0x781C6D, 0x7A1D6D, 0x7C1D6D,
        0x7D1E6D, 0x7F1E6C, 0x801F6C, 0x82206C, 0x84206B, 0x85216B, 0x87216B, 0x88226A,
        0x8A226A, 0x8C2369, 0x8D2369, 0x8F2469, 0x902568, 0x922568, 0x932667, 0x952667,
        0x972766, 0x982766, 0x9A2865, 0x9B2964, 0x9D2964, 0x9F2A63, 0xA02A63, 0xA22B62,
        0xA32C61, 0xA52C60, 0xA62D60, 0xA82E5F, 0xA92E5E, 0xAB2F5E, 0xAD305D, 0xAE305C,
        0xB0315B, 0xB1325A, 0xB3325A, 0xB43359, 0xB63458, 0xB73557, 0xB93556, 0xBA3655,
        0xBC3754, 0xBD3853, 0xBF3952, 0xC03A51, 0xC13A50, 0xC33B4F, 0xC43C4E, 0xC63D4D,
        0xC73E4C, 0xC83F4B, 0xCA404A, 0xCB4149, 0xCC4248, 0xCE4347, 0xCF4446, 0xD04545,
        0xD24644, 0xD34743, 0xD44842, 0xD54A41, 0xD74B3F, 0xD84C3E, 0xD94D3D, 0xDA4E3C,
        0xDB503B, 0xDD513A, 0xDE5238, 0xDF5337, 0xE05536, 0xE15635, 0xE25734, 0xE35933,
        0xE45A31, 0xE55C30, 0xE65D2F, 0xE75E2E, 0xE8602D, 0xE9612B, 0xEA632A, 0xEB6429,
        0xEB6628, 0xEC6726, 0xED6925, 0xEE6A24, 0xEF6C23, 0xEF6E21, 0xF06F20, 0xF1711F,
        0xF1731D, 0xF2741C, 0xF3761B, 0xF37819, 0xF47918, 0xF57B17, 0xF57D15, 0xF67E14,
        0xF68013, 0xF78212, 0xF78410, 0xF8850F, 0xF8870E, 0xF8890C, 0xF98B0B, 0xF98C0A,
        0xF98E09, 0xFA9008, 0xFA9207, 0xFA9407, 0xFB9606, 0xFB9706, 0xFB9906, 0xFB9B06,
        0xFB9D07, 0xFC9F07, 0xFCA108, 0xFCA309, 0xFCA50A, 0xFCA60C, 0xFCA80D, 0xFCAA0F,
        0xFCAC11, 0xFCAE12, 0xFCB014, 0xFCB216, 0xFCB418, 0xFBB61A, 0xFBB81D, 0xFBBA1F,
        0xFBBC21, 0xFBBE23, 0xFAC026, 0xFAC228, 0xFAC42A, 0xFAC62D, 0xF9C72F, 0xF9C932,
        0xF9CB35, 0xF8CD37, 0xF8CF3A, 0xF7D13D, 0xF7D340, 0xF6D543, 0xF6D746, 0xF5D949,
        0xF5DB4C, 0xF4DD4F, 0xF4DF53, 0xF4E156, 0xF3E35A, 0xF3E55D, 0xF2E661, 0xF2E865,
        0xF2EA69, 0xF1EC6D, 0xF1ED71, 0xF1EF75, 0xF1F179, 0xF2F27D, 0xF2F482, 0xF3F586,
        0xF3F68A, 0xF4F88E, 0xF5F992, 0xF6FA96, 0xF8FB9A, 0xF9FC9D, 0xFAFDA1, 0xFCFFA4,
    ]
}
