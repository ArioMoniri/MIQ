import Foundation

/// A rectangle in view coordinates, AppKit convention: y grows **upwards**
/// (`minY` is the bottom edge). Portable stand-in for `CGRect` so the zoom/pan
/// math is testable on Linux without CoreGraphics.
public struct ViewportRect: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var isEmpty: Bool { !(width > 0 && height > 0) }

    /// Half-open containment, like `CGRect.contains`.
    public func contains(_ point: ViewportPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}

/// A point in view coordinates (y up), or — where documented — a normalized
/// image position (`x` 0 = left edge, 1 = right edge; `y` 0 = **top**, 1 =
/// bottom, matching `MIQNormalizedPoint`).
public struct ViewportPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Zoom and pan of one slice panel, relative to the image's aspect-fit rect.
///
/// The model is the minimum needed for magnifier-style navigation:
/// * `zoom` ≥ 1 scales the fitted image about…
/// * …`center`, the normalized image position (y down, like
///   `MIQNormalizedPoint`) that sits at the fitted rect's centre.
///
/// `center` is clamped so the zoomed image always covers the whole fitted rect
/// (no black margins open up while panning); at `zoom == 1` that forces the
/// centre to (0.5, 0.5), so identity is unique. The panel draws the image into
/// `drawnRect(fitted:)` clipped to the fitted rect, and maps clicks back with
/// `normalizedPoint(at:fitted:)` — the same normalized point the unzoomed
/// canvas produced, so the model's cursor → voxel mapping is unchanged.
public struct ViewportTransform: Sendable, Hashable {
    public static let minZoom: Double = 1
    public static let maxZoom: Double = 16

    public private(set) var zoom: Double
    /// Normalized image x at the fitted rect's centre.
    public private(set) var centerX: Double
    /// Normalized image y (0 = top) at the fitted rect's centre.
    public private(set) var centerY: Double

    public static let identity = ViewportTransform()

    public init(zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5) {
        let z = zoom.isFinite ? min(Self.maxZoom, max(Self.minZoom, zoom)) : 1
        self.zoom = z
        self.centerX = Self.clampCenter(centerX, zoom: z)
        self.centerY = Self.clampCenter(centerY, zoom: z)
    }

    /// True when the panel shows the plain aspect-fit image.
    public var isIdentity: Bool { zoom <= Self.minZoom + 1e-9 }

    /// Keeps `[c - 0.5/z, c + 0.5/z]` inside `[0, 1]`.
    static func clampCenter(_ value: Double, zoom: Double) -> Double {
        let half = 0.5 / zoom
        guard value.isFinite else { return 0.5 }
        return min(1 - half, max(half, value))
    }

    /// Where the whole (zoomed) image is drawn. Larger than `fitted` when
    /// zoomed in; the caller clips to `fitted`.
    public func drawnRect(fitted: ViewportRect) -> ViewportRect {
        let w = fitted.width * zoom
        let h = fitted.height * zoom
        // Image x = centerX lands on fitted.midX; image y = centerY (top-down)
        // lands on fitted.midY, so the image's top edge is centerY·h above it.
        let maxY = fitted.midY + centerY * h
        return ViewportRect(x: fitted.midX - centerX * w, y: maxY - h, width: w, height: h)
    }

    /// Normalized image point (y down) under `point`, or `nil` when `point` is
    /// outside the visible (fitted) area or the rect is degenerate. Values are
    /// clamped to [0, 1].
    public func normalizedPoint(at point: ViewportPoint, fitted: ViewportRect) -> ViewportPoint? {
        guard !fitted.isEmpty, fitted.contains(point) else { return nil }
        return unclampedNormalizedPoint(at: point, fitted: fitted).map {
            ViewportPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y)))
        }
    }

    func unclampedNormalizedPoint(at point: ViewportPoint, fitted: ViewportRect) -> ViewportPoint? {
        let drawn = drawnRect(fitted: fitted)
        guard !drawn.isEmpty else { return nil }
        return ViewportPoint(
            x: (point.x - drawn.minX) / drawn.width,
            y: (drawn.maxY - point.y) / drawn.height
        )
    }

    /// View position of a normalized image point (inverse of `normalizedPoint`).
    public func viewPoint(forNormalized p: ViewportPoint, fitted: ViewportRect) -> ViewportPoint {
        let drawn = drawnRect(fitted: fitted)
        return ViewportPoint(x: drawn.minX + p.x * drawn.width, y: drawn.maxY - p.y * drawn.height)
    }

    /// Zoom by `factor` keeping the image point under `anchor` fixed on screen
    /// (pinch / ⌘-scroll around the cursor). An anchor outside `fitted` zooms
    /// about the centre.
    public func zoomed(by factor: Double, anchor: ViewportPoint, fitted: ViewportRect) -> ViewportTransform {
        guard factor.isFinite, factor > 0, !fitted.isEmpty else { return self }
        let newZoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
        let effectiveAnchor = fitted.contains(anchor) ? anchor : ViewportPoint(x: fitted.midX, y: fitted.midY)
        guard let p = unclampedNormalizedPoint(at: effectiveAnchor, fitted: fitted) else { return self }
        let w = fitted.width * newZoom
        let h = fitted.height * newZoom
        // Solve drawnRect' so p stays at the anchor:
        //   anchor.x = midX + (p.x - cx')·w   ⇒ cx' = p.x - (anchor.x - midX)/w
        //   anchor.y = midY + (cy' - p.y)·h   ⇒ cy' = p.y + (anchor.y - midY)/h
        let cx = p.x - (effectiveAnchor.x - fitted.midX) / w
        let cy = p.y + (effectiveAnchor.y - fitted.midY) / h
        return ViewportTransform(zoom: newZoom, centerX: cx, centerY: cy)
    }

    /// Pan by a view-space drag delta (y up): the image follows the pointer.
    public func panned(dx: Double, dy: Double, fitted: ViewportRect) -> ViewportTransform {
        guard !fitted.isEmpty, dx.isFinite, dy.isFinite else { return self }
        let w = fitted.width * zoom
        let h = fitted.height * zoom
        return ViewportTransform(zoom: zoom, centerX: centerX - dx / w, centerY: centerY + dy / h)
    }

    /// The normalized image sub-rectangle currently visible (y down):
    /// `(x0, y0)` top-left to `(x1, y1)` bottom-right.
    public var visibleNormalizedRegion: (x0: Double, y0: Double, x1: Double, y1: Double) {
        let half = 0.5 / zoom
        return (centerX - half, centerY - half, centerX + half, centerY + half)
    }

    /// Integer pixel (column, row) of a `width × height` image under `point`,
    /// using the same "floor, clamp to the last pixel" rule as
    /// `MIQVolume.cursor(for:sliceIndex:normalizedPoint:…)`. `nil` outside.
    public func pixel(at point: ViewportPoint, fitted: ViewportRect, width: Int, height: Int) -> (column: Int, row: Int)? {
        guard width > 0, height > 0, let p = normalizedPoint(at: point, fitted: fitted) else { return nil }
        let column = min(width - 1, max(0, Int((p.x * Double(width)).rounded(.down))))
        let row = min(height - 1, max(0, Int((p.y * Double(height)).rounded(.down))))
        return (column, row)
    }
}
