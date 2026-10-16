import Foundation

/// Interleaved RGBA8888 pixel buffer (alpha fixed at 255), laid out exactly as
/// the CGImage the preview wraps it in. Produced from a `SliceImage` in a
/// single pass directly into the `Data` a `CGDataProvider` shares without
/// copying — so the per-pixel expansion runs wherever `rgbaBitmap()` is called
/// (the preview model calls it inside its detached render task, off the
/// MainActor) and the main thread only creates the cheap CGImage/NSImage
/// wrappers around the finished buffer.
public struct RGBABitmap: Sendable {
    public let width: Int
    public let height: Int
    /// Interleaved RGBA bytes — length == width * height * 4.
    public let pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

extension SliceImage {
    /// Expands this slice to an RGBA8888 bitmap, or `nil` when the pixel buffer
    /// doesn't match the declared dimensions (the same guard the AppKit bridge
    /// applied before building a CGImage).
    public func rgbaBitmap() -> RGBABitmap? {
        switch self {
        case .grayscale(let img):
            guard img.width > 0, img.height > 0, img.pixels.count == img.width * img.height else {
                return nil
            }
            return RGBABitmap(width: img.width, height: img.height, pixels: Self.expandToRGBA(img.pixels, channels: 1))
        case .rgb(let img):
            guard img.width > 0, img.height > 0, img.pixels.count == img.width * img.height * 3 else {
                return nil
            }
            return RGBABitmap(width: img.width, height: img.height, pixels: Self.expandToRGBA(img.pixels, channels: 3))
        }
    }

    private static func expandToRGBA(_ source: [UInt8], channels: Int) -> Data {
        let pixelCount = source.count / channels
        var data = Data(count: pixelCount * 4)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            source.withUnsafeBufferPointer { srcBuf in
                guard let src = srcBuf.baseAddress else { return }
                var r = 0
                var w = 0
                if channels == 1 {
                    for _ in 0..<pixelCount {
                        let g = src[r]
                        dst[w] = g
                        dst[w + 1] = g
                        dst[w + 2] = g
                        dst[w + 3] = 255
                        r += 1
                        w += 4
                    }
                } else {
                    for _ in 0..<pixelCount {
                        dst[w] = src[r]
                        dst[w + 1] = src[r + 1]
                        dst[w + 2] = src[r + 2]
                        dst[w + 3] = 255
                        r += 3
                        w += 4
                    }
                }
            }
        }
        return data
    }
}

/// Single-channel 8-bit grayscale pixel buffer — a quarter of the memory of the
/// equivalent `RGBABitmap`, for a grayscale slice wrapped in a
/// `CGColorSpaceCreateDeviceGray()` / 8 bpc / 8 bpp / `CGImageAlphaInfo.none`
/// CGImage instead of an RGBA one. Rows are tightly packed
/// (`bytesPerRow == width`).
public struct Gray8Bitmap: Sendable {
    public let width: Int
    public let height: Int
    /// Grey levels, row-major — length == width * height.
    public let pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

extension GrayscaleImage {
    /// This image as a `Gray8Bitmap` (the pixels copied once into `Data`, which a
    /// `CGDataProvider` can then share without another copy), or `nil` when the
    /// buffer doesn't match the declared dimensions — the same guard as
    /// `SliceImage.rgbaBitmap()`. Each byte equals the R (= G = B) byte of the
    /// corresponding `rgbaBitmap()` pixel.
    public func makeGray8() -> Gray8Bitmap? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        return Gray8Bitmap(width: width, height: height, pixels: Data(pixels))
    }
}

extension SliceImage {
    /// Single-channel output for grayscale slices (`GrayscaleImage.makeGray8()`);
    /// `nil` for RGB slices (colour data, segmentation LUTs), which need
    /// `rgbaBitmap()`, and for a mismatched buffer.
    public func makeGray8() -> Gray8Bitmap? {
        guard case .grayscale(let img) = self else { return nil }
        return img.makeGray8()
    }
}
