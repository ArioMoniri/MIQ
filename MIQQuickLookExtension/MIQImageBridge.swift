import AppKit
import MIQCore

enum MIQImageBridge {
    /// Convenience for callers without a pre-expanded bitmap (the thumbnail
    /// provider's one-shot render). Grayscale slices take the 8-bit grey path
    /// (`SliceImage.previewBitmap()`); colour data and LUT output stay RGBA. The
    /// preview model instead builds the bitmap inside its detached render task
    /// and hands the MainActor only the bitmap overloads below.
    static func makeNSImage(from slice: SliceImage) -> NSImage? {
        slice.previewBitmap().flatMap(makeNSImage(from:))
    }

    static func makeNSImage(from bitmap: PreviewSliceBitmap) -> NSImage? {
        switch bitmap {
        case .gray(let gray): return makeNSImage(from: gray)
        case .rgba(let rgba): return makeNSImage(from: rgba)
        }
    }

    /// Cheap by design — this is the only part that must run on the MainActor.
    /// The per-pixel expansion already happened in `rgbaBitmap()`, and
    /// `bitmap.pixels as CFData` bridges without copying (the CGImage retains
    /// the buffer through the provider), so no pixel pass happens here.
    static func makeNSImage(from bitmap: RGBABitmap) -> NSImage? {
        guard bitmap.width > 0, bitmap.height > 0,
              bitmap.pixels.count == bitmap.width * bitmap.height * 4,
              let provider = CGDataProvider(data: bitmap.pixels as CFData),
              let cgImage = CGImage(
                width: bitmap.width,
                height: bitmap.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: bitmap.width, height: bitmap.height))
    }

    /// Single-channel counterpart of the RGBA overload: 8 bits per component,
    /// one component per pixel, a device-gray colour space and no alpha
    /// (`CGImageAlphaInfo.none`), rows tightly packed. A quarter of the RGBA
    /// image's memory for the same grey levels (each byte equals the R = G = B
    /// byte the RGBA path would carry — pinned in `PreviewBitmapTests`). Also
    /// zero-copy: the provider retains `bitmap.pixels`.
    static func makeNSImage(from bitmap: Gray8Bitmap) -> NSImage? {
        guard bitmap.width > 0, bitmap.height > 0,
              bitmap.pixels.count == bitmap.width * bitmap.height,
              let provider = CGDataProvider(data: bitmap.pixels as CFData),
              let cgImage = CGImage(
                width: bitmap.width,
                height: bitmap.height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: bitmap.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: bitmap.width, height: bitmap.height))
    }
}
