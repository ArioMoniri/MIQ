import AppKit

/// Copy-the-view export for the preview: the visible mosaic (or maximised
/// panel) as PNG + TIFF on the general pasteboard.
///
/// There is deliberately no "Save PNG…": the extension's sandbox has no
/// user-selected-file write entitlement, and a modal NSSavePanel from a Quick
/// Look preview extension (hosted out of process by Finder / the Quick Look
/// panel) isn't something Apple documents as supported, so it stays out.
/// Copy, then paste into any app, covers the need without new entitlements.
@MainActor
enum MIQExport {
    /// What is drawn in `view` right now, on an opaque black background (the
    /// panel gutters are the parent layer's colour, which `cacheDisplay`
    /// doesn't capture), at the backing scale.
    static func snapshot(of view: NSView) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let captured = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: captured)

        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: captured.pixelsWide,
            pixelsHigh: captured.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: output) else { return captured }
        output.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        NSColor.black.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        captured.draw(in: NSRect(origin: .zero, size: bounds.size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return output
    }

    /// Puts `view`'s current image on the general pasteboard as PNG and TIFF.
    /// Returns false when nothing could be captured.
    @discardableResult
    static func copyToPasteboard(_ view: NSView) -> Bool {
        guard let rep = snapshot(of: view) else { return false }
        let png = rep.representation(using: .png, properties: [:])
        let tiff = rep.tiffRepresentation
        guard png != nil || tiff != nil else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = []
        if png != nil { types.append(.png) }
        if tiff != nil { types.append(.tiff) }
        pasteboard.declareTypes(types, owner: nil)
        if let png { pasteboard.setData(png, forType: .png) }
        if let tiff { pasteboard.setData(tiff, forType: .tiff) }
        return true
    }
}
