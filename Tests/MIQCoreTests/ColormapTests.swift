import Foundation
import Testing
@testable import MIQCore

struct ColormapTests {

    @Test func everyMapHas256OpaqueEntries() {
        for map in Colormap.allCases {
            #expect(map.table.count == 256)
            #expect(map.table.allSatisfy { $0.a == 255 })
        }
    }

    @Test func grayscaleIsIdentity() {
        for i in [0, 1, 127, 254, 255] {
            let c = Colormap.grayscale.color(UInt8(i))
            #expect(c == RGBA8(r: UInt8(i), g: UInt8(i), b: UInt8(i)))
        }
    }

    /// Endpoints of the matplotlib tables (0.267004, 0.004874, 0.329415) →
    /// #440154 and (0.993248, 0.906157, 0.143936) → #FDE725.
    @Test func viridisAndInfernoMatchMatplotlibEndpoints() {
        #expect(Colormap.viridis.color(0) == RGBA8(r: 0x44, g: 0x01, b: 0x54))
        #expect(Colormap.viridis.color(255) == RGBA8(r: 0xFD, g: 0xE7, b: 0x25))
        #expect(Colormap.inferno.color(0) == RGBA8(r: 0x00, g: 0x00, b: 0x04))
        #expect(Colormap.inferno.color(255) == RGBA8(r: 0xFC, g: 0xFF, b: 0xA4))
    }

    @Test func hotCoolWinterShapes() {
        #expect(Colormap.hot.color(255) == RGBA8(r: 255, g: 255, b: 255))
        let hotMid = Colormap.hot.color(128)
        #expect(hotMid.r == 255 && hotMid.b == 0)
        #expect(Colormap.cool.color(0) == RGBA8(r: 0, g: 255, b: 255))
        #expect(Colormap.cool.color(255) == RGBA8(r: 255, g: 0, b: 255))
        #expect(Colormap.winter.color(0) == RGBA8(r: 0, g: 0, b: 255))
        #expect(Colormap.winter.color(255) == RGBA8(r: 0, g: 255, b: 128))
    }

    @Test func divergingIsSymmetricAroundZero() {
        let mapping = ScalarColorMapping.diverging(limit: 2)
        #expect(mapping.color(for: -2) == RGBA8(r: 33, g: 102, b: 172))
        #expect(mapping.color(for: 2) == RGBA8(r: 178, g: 24, b: 43))
        let zero = mapping.color(for: 0)
        #expect(zero.r >= 250 && zero.g >= 250 && zero.b >= 250)
        // Out-of-range values clamp to the ends.
        #expect(mapping.color(for: -50) == mapping.color(for: -2))
        // Asymmetric window is symmetrised by max(|low|, |high|).
        let asym = ScalarColorMapping(colormap: .diverging, low: -1, high: 4)
        #expect(asym.normalizedPosition(0) == 0.5)
        #expect(asym.normalizedPosition(-4) == 0)
    }

    @Test func divergingThresholdHidesBothSidesNearZero() {
        let mapping = ScalarColorMapping.diverging(limit: 5, threshold: 2.3)
        #expect(mapping.color(for: 0).a == 0)
        #expect(mapping.color(for: 2.2).a == 0)
        #expect(mapping.color(for: -2.2).a == 0)
        let pos = mapping.color(for: 3)
        let neg = mapping.color(for: -3)
        #expect(pos.a == 255 && pos.r > pos.b)
        #expect(neg.a == 255 && neg.b > neg.r)
        #expect(mapping.color(for: .nan).a == 0)
    }

    @Test func sequentialThresholdAndBitmap() throws {
        let mapping = ScalarColorMapping(colormap: .hot, low: 0, high: 10, threshold: 3)
        let bmp = try #require(mapping.rgbaBitmap(values: [0, 2.9, 3, 10], width: 2, height: 2))
        let p = [UInt8](bmp.pixels)
        #expect(p[3] == 0 && p[7] == 0)
        #expect(p[11] == 255 && p[15] == 255)
        #expect(Array(p[12..<15]) == [255, 255, 255])
        #expect(mapping.rgbaBitmap(values: [1, 2, 3], width: 2, height: 2) == nil)
    }

    @Test func grayscaleImageThroughColormap() throws {
        let img = GrayscaleImage(width: 2, height: 1, pixels: [0, 255])
        let bmp = try #require(img.rgbaBitmap(colormap: .viridis))
        #expect([UInt8](bmp.pixels) == [0x44, 0x01, 0x54, 255, 0xFD, 0xE7, 0x25, 255])
    }

    @Test func suggestionRules() {
        #expect(Colormap.suggested(intentCode: 5, minValue: 0, maxValue: 1, isFloatingPoint: true) == .diverging)
        #expect(Colormap.suggested(intentCode: 3, minValue: 0, maxValue: 1, isFloatingPoint: true) == .diverging)
        #expect(Colormap.suggested(intentCode: 4, minValue: 0, maxValue: 9, isFloatingPoint: true) == .hot)
        #expect(Colormap.suggested(intentCode: nil, minValue: -4, maxValue: 6, isFloatingPoint: true) == .diverging)
        #expect(Colormap.suggested(intentCode: nil, minValue: -0.1, maxValue: 1000, isFloatingPoint: true) == .grayscale)
        #expect(Colormap.suggested(intentCode: nil, minValue: -4, maxValue: 6, isFloatingPoint: false) == .grayscale)
        #expect(Colormap.suggested(intentCode: 0, minValue: 0, maxValue: 6, isFloatingPoint: true) == .grayscale)
    }

    @Test func intentCodeIsReadFromNiftiHeader() throws {
        let data = ModalityFixtures.niftiBytes(dims: [2, 2, 2], intentCode: 5, values: [Float](repeating: 0, count: 8))
        let vol = try ModalityFixtures.niftiVolume(data)
        #expect(vol.niftiIntentCode == 5)
        let plain = ModalityFixtures.floatVolume(width: 1, height: 1, depth: 1, values: [0])
        #expect(plain.niftiIntentCode == nil)
    }
}
