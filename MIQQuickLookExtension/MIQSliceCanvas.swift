import AppKit
import MIQCore

extension ScrollStepInput {
    /// Map an `NSEvent` to the AppKit-free input the resolver consumes.
    init(_ event: NSEvent) {
        self.init(
            optionHeld: event.modifierFlags.contains(.option),
            phaseBegan: event.phase.contains(.began),
            isLegacyWheel: event.phase == [] && event.momentumPhase == [],
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
    }
}

/// Cross-view coordination for the full-screen orphaned-event rescue: while
/// the volume scrubber owns a left-drag gesture, the slice canvases must not
/// claim window-less drag events that wander over an image (the responder
/// chain's mouse capture would have kept them at the scrubber).
@MainActor
enum FullScreenEventRescue {
    static var scrubInProgress = false
}

/// Input state shared by the three canvases.
@MainActor
enum MIQPanKeyState {
    /// Space-bar state for Space-drag panning, tracked by the preview root
    /// view's key handling (Space is not a modifier flag, so the canvases can't
    /// read it off the event).
    static var spaceHeld = false
    /// The left-button press already handled — by whichever canvas saw it
    /// first, through the early monitor or `mouseDown`. Shared, not per
    /// canvas: a double-click that maximises/restores re-arranges the panels
    /// mid-dispatch, and a sibling (whose stale frame still covers the point)
    /// must not act on the same press again.
    static var lastHandledClickEventNumber: Int?
}

extension ViewportRect {
    init(_ rect: NSRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    var nsRect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

extension ViewportPoint {
    init(_ point: NSPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }
}

final class MIQSliceCanvas: NSView {
    enum HorizontalImageAlignment {
        case leading
        case trailing
    }

    enum VerticalImageAlignment {
        case top
        case bottom
    }

    struct ImageAlignment {
        let horizontal: HorizontalImageAlignment
        let vertical: VerticalImageAlignment
    }

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var orientation: SliceOrientationLabels {
        didSet { needsDisplay = true }
    }

    var labelFontSize: CGFloat = 11 {
        didSet { needsDisplay = true }
    }

    var showAxisLabels: Bool = true {
        didSet { needsDisplay = true }
    }

    var labelColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    var crosshair: MIQNormalizedPoint? {
        didSet { needsDisplay = true }
    }

    /// Zoom / pan relative to the aspect-fit rect. Identity = the classic view.
    var viewport: ViewportTransform = .identity {
        didSet { if viewport != oldValue { needsDisplay = true } }
    }

    /// Window/level text ("W 80 / L 40") drawn in the bottom-left corner, or
    /// `nil` to hide it.
    var windowBadge: String? {
        didSet { if windowBadge != oldValue { needsDisplay = true } }
    }

    /// VoiceOver label, e.g. "Axial slice 45 of 90, window W 80 / L 40".
    var accessibilitySliceLabel: String = "" {
        didSet { if accessibilitySliceLabel != oldValue { setAccessibilityLabel(accessibilitySliceLabel) } }
    }

    var onScrollGestureBegan: (@MainActor () -> Void)?
    var onScroll: (@MainActor (SlicePlane, Int) -> Void)?
    /// Option-modifier scroll: step the 4th (volume/time) axis instead of the
    /// in-plane slice. Plane-agnostic — the 4th axis is not spatial.
    var onVolumeScroll: (@MainActor (Int) -> Void)?
    var onCursorPosition: (@MainActor (SlicePlane, MIQNormalizedPoint) -> Void)?
    var onWindowAdjust: (@MainActor (CGFloat, CGFloat) -> Void)?
    var onDoubleClick: (@MainActor (SlicePlane) -> Void)?
    /// Secondary click without a drag, or ⌃-click: show the context menu.
    var onContextMenu: (@MainActor (SlicePlane, NSEvent) -> Void)?
    /// Any primary click: this plane becomes the active one (keyboard focus,
    /// projection plane).
    var onActivate: (@MainActor (SlicePlane) -> Void)?

    private let plane: SlicePlane
    private let imageAlignment: ImageAlignment
    private var scrollResolver = ScrollStepResolver()
    private var earlyClickMonitor: Any?
    /// Pan drag in progress (⇧- or Space-drag, middle-drag) and its last point.
    private var panAnchor: NSPoint?
    /// A secondary-button press moved: it was a W/L drag, not a menu click.
    private var secondaryDragged = false
    #if DEBUG
    var debugBorderColor: NSColor = .cyan
    #endif

    init(plane: SlicePlane, imageAlignment: ImageAlignment, orientation: SliceOrientationLabels) {
        self.plane = plane
        self.imageAlignment = imageAlignment
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder _: NSCoder) {
        return nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let earlyClickMonitor {
            NSEvent.removeMonitor(earlyClickMonitor)
            self.earlyClickMonitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Two jobs: handle clicks immediately (bypassing the QuickLook host's
        // gesture-recognizer delay), and rescue the window-less events the
        // full-screen host produces (see handleOrphanedEvent).
        let observed: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .rightMouseDragged, .scrollWheel
        ]
        earlyClickMonitor = NSEvent.addLocalMonitorForEvents(matching: observed) { [weak self] event in
            MainActor.assumeIsolated {
                // The monitor is process-wide: a canvas hidden behind a
                // maximised panel shares its frame and must not react.
                guard let self, !self.isHiddenOrHasHiddenAncestor else { return }
                if event.type == .leftMouseDown {
                    self.handleEarlyMouseDown(event)
                } else if event.window == nil {
                    self.handleOrphanedEvent(event)
                }
            }
            return event
        }
    }

    /// Rescue path for full-screen Quick Look. The full-screen host forwards
    /// drag sequences (and most scroll events) into this process with
    /// `event.window == nil`; AppKit drops window-less events before responder
    /// dispatch, so without this the crosshair drag is dead and scrolling
    /// stutters on the ~10% of events that are properly addressed. Per AppKit's
    /// contract, a window-less event's `locationInWindow` is in *screen*
    /// coordinates, and the full-screen service window has a real screen-space
    /// frame, so the position converts cleanly. Only the visible instance may
    /// act (the Finder-column preview lives in the same process, occluded), and
    /// only window-less events are handled here — properly addressed events
    /// keep the normal responder path, so windowed behavior is unchanged.
    private func handleOrphanedEvent(_ event: NSEvent) {
        guard let window, window.occlusionState.contains(.visible) else { return }
        let windowPoint = window.convertPoint(fromScreen: event.locationInWindow)
        let location = convert(windowPoint, from: nil)
        guard imageRect().contains(location) else { return }

        switch event.type {
        case .leftMouseDragged:
            guard !FullScreenEventRescue.scrubInProgress else { return }
            if panAnchor != nil {
                continuePan(to: location)
            } else {
                notifyCursorPosition(at: location)
            }
        case .rightMouseDragged:
            secondaryDragged = true
            onWindowAdjust?(event.deltaX, event.deltaY)
        case .scrollWheel:
            handleScroll(event, at: location)
        default:
            break
        }
    }

    private func handleEarlyMouseDown(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        // ⌃-click opens a menu: leave it to the normal mouseDown rather than
        // running a modal menu loop from inside an event monitor.
        guard !event.modifierFlags.contains(.control) else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location),
              MIQPanKeyState.lastHandledClickEventNumber != event.eventNumber else { return }
        MIQPanKeyState.lastHandledClickEventNumber = event.eventNumber
        handlePrimaryMouseDown(event, at: location)
    }

    /// Shared by the early monitor and `mouseDown` (whichever sees the press
    /// first): ⌃-click → menu, double-click → maximise / reset zoom,
    /// ⇧- or Space-press on a zoomed panel → start a pan, else crosshair.
    private func handlePrimaryMouseDown(_ event: NSEvent, at location: NSPoint) {
        onActivate?(plane)
        if event.modifierFlags.contains(.control) {
            panAnchor = nil
            onContextMenu?(plane, event)
            return
        }
        if event.clickCount >= 2 {
            panAnchor = nil
            onDoubleClick?(plane)
            return
        }
        if !viewport.isIdentity, event.modifierFlags.contains(.shift) || MIQPanKeyState.spaceHeld {
            panAnchor = location
            return
        }
        panAnchor = nil
        notifyCursorPosition(at: location)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location) else {
            super.mouseDown(with: event)
            return
        }
        // The early local monitor already handled this click immediately on press,
        // bypassing the QuickLook host's gesture-recognizer delay. Skip the duplicate.
        if MIQPanKeyState.lastHandledClickEventNumber == event.eventNumber { return }
        MIQPanKeyState.lastHandledClickEventNumber = event.eventNumber
        handlePrimaryMouseDown(event, at: location)
    }

    override func mouseUp(with event: NSEvent) {
        panAnchor = nil
        super.mouseUp(with: event)
    }

    // The secondary button does two things: drag = window/level (unchanged),
    // click without moving = context menu. The press itself is swallowed so
    // AppKit's default (an immediate menu-on-press) can't pre-empt the drag.
    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location) else {
            super.rightMouseDown(with: event)
            return
        }
        secondaryDragged = false
    }

    override func rightMouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location) else {
            super.rightMouseDragged(with: event)
            return
        }
        secondaryDragged = true
        onWindowAdjust?(event.deltaX, event.deltaY)
    }

    override func rightMouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        defer { secondaryDragged = false }
        guard !secondaryDragged, imageRect().contains(location) else {
            super.rightMouseUp(with: event)
            return
        }
        onContextMenu?(plane, event)
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if panAnchor != nil {
            continuePan(to: location)
            return
        }
        guard imageRect().contains(location) else {
            super.mouseDragged(with: event)
            return
        }
        notifyCursorPosition(at: location)
    }

    // Middle-button drag pans a zoomed panel too (no modifier needed).
    override func otherMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard !viewport.isIdentity, imageRect().contains(location) else {
            super.otherMouseDown(with: event)
            return
        }
        panAnchor = location
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard panAnchor != nil else {
            super.otherMouseDragged(with: event)
            return
        }
        continuePan(to: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseUp(with event: NSEvent) {
        panAnchor = nil
        super.otherMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location) else {
            super.scrollWheel(with: event)
            return
        }
        handleScroll(event, at: location)
    }

    /// ⌘-scroll zooms about the cursor; on a zoomed panel a precise
    /// (trackpad) two-finger scroll pans; everything else is the unchanged
    /// slice / ⌥-volume stepping.
    private func handleScroll(_ event: NSEvent, at location: NSPoint) {
        let fitted = ViewportRect(imageRect())
        if event.modifierFlags.contains(.command) {
            let delta = Double(event.scrollingDeltaY)
            guard delta != 0 else { return }
            let perPoint = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            viewport = viewport.zoomed(by: exp(delta * perPoint), anchor: ViewportPoint(location), fitted: fitted)
            return
        }
        if !viewport.isIdentity, event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.option) {
            // Content follows the fingers: +deltaY moves it down (y-up: negative).
            viewport = viewport.panned(dx: Double(event.scrollingDeltaX), dy: -Double(event.scrollingDeltaY), fitted: fitted)
            return
        }
        guard let outcome = scrollResolver.resolve(ScrollStepInput(event), onBegan: { [weak self] in
            self?.onScrollGestureBegan?()
        }) else { return }

        switch outcome.axis {
        case .slice:  onScroll?(plane, outcome.step)
        case .volume: onVolumeScroll?(outcome.step)
        }
    }

    override func magnify(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        viewport = viewport.zoomed(
            by: 1 + Double(event.magnification),
            anchor: ViewportPoint(location),
            fitted: ViewportRect(imageRect())
        )
    }

    /// Two-finger double-tap: zoom 2× at the pointer, or back to fit.
    override func smartMagnify(with event: NSEvent) {
        if viewport.isIdentity {
            let location = convert(event.locationInWindow, from: nil)
            viewport = viewport.zoomed(by: 2, anchor: ViewportPoint(location), fitted: ViewportRect(imageRect()))
        } else {
            viewport = .identity
        }
    }

    private func continuePan(to location: NSPoint) {
        guard let anchor = panAnchor else { return }
        panAnchor = location
        viewport = viewport.panned(
            dx: Double(location.x - anchor.x),
            dy: Double(location.y - anchor.y),
            fitted: ViewportRect(imageRect())
        )
    }

    override func draw(_: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        let viewportRect = bounds

        #if DEBUG
        if MIQConfig.debugShowLayoutBorders {
            debugBorderColor.setStroke()
            let debugBorder = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            debugBorder.lineWidth = 2
            debugBorder.stroke()
        }
        #endif

        if let image {
            // `fitted` is where the whole image sits unzoomed (and the clip);
            // `drawn` is the zoomed image, larger than `fitted` when zoomed in.
            let fitted = aspectFitRect(for: image.size, inside: viewportRect)
            let drawn = viewport.drawnRect(fitted: ViewportRect(fitted)).nsRect

            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: fitted)
            clip.addClip()
            // Voxels must stay crisp blocks when upscaled: the default interpolation
            // (usually bilinear or better) would blur them and invent intermediate
            // intensities. Restored explicitly below rather than relying on the
            // gstate save/restore, which AppKit does not document as covering it.
            let context = NSGraphicsContext.current
            let previousInterpolation = context?.imageInterpolation
            context?.imageInterpolation = .none

            image.draw(
                in: drawn,
                from: .zero,
                operation: .copy,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )

            if let previousInterpolation { context?.imageInterpolation = previousInterpolation }

            // Inside the clip: under zoom the crosshair lines extend past the
            // visible area.
            if let crosshair {
                drawCrosshair(crosshair, in: drawn)
            }
            NSGraphicsContext.restoreGraphicsState()

            if showAxisLabels {
                drawAxisLabels(for: fitted, within: viewportRect)
            }

            if !viewport.isIdentity {
                drawBadge(String(format: "%.1f×", viewport.zoom), trailing: true)
            }
        }

        if let windowBadge {
            drawBadge(windowBadge, trailing: false)
        }
    }

    /// Small legible text in a bottom corner of the panel, on a dark pill so
    /// it reads over bright anatomy.
    private func drawBadge(_ text: String, trailing: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, labelFontSize), weight: .medium),
            .foregroundColor: labelColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 3
        let inset: CGFloat = 4
        let width = size.width + 2 * padding
        let x = trailing ? bounds.maxX - inset - width : bounds.minX + inset
        let pill = NSRect(x: x, y: bounds.minY + inset, width: width, height: size.height + padding)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + padding, y: pill.minY + padding / 2), withAttributes: attrs)
    }

    private func aspectFitRect(for size: NSSize, inside rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }

        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale
        let h = size.height * scale

        let x: CGFloat
        switch imageAlignment.horizontal {
        case .leading:
            x = rect.minX
        case .trailing:
            x = rect.maxX - w
        }

        let y: CGFloat
        switch imageAlignment.vertical {
        case .top:
            y = rect.maxY - h
        case .bottom:
            y = rect.minY
        }

        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func drawAxisLabels(for imageRect: NSRect, within boundsRect: NSRect) {
        let cx = imageRect.midX
        let cy = imageRect.midY

        // Unknown-orientation labels render dimmed to signal that the "?" glyphs are
        // a placeholder rather than a confident anatomical claim.
        let effectiveColor = orientation.isUnknown
            ? labelColor.withAlphaComponent(0.35)
            : labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: labelFontSize, weight: .semibold),
            .foregroundColor: effectiveColor
        ]

        let margin: CGFloat = 1

        let leadingSize = (orientation.leading as NSString).size(withAttributes: attrs)
        let trailingSize = (orientation.trailing as NSString).size(withAttributes: attrs)
        let topSize = (orientation.top as NSString).size(withAttributes: attrs)
        let bottomSize = (orientation.bottom as NSString).size(withAttributes: attrs)

        let leadingX = max(boundsRect.minX + 1, imageRect.minX - leadingSize.width - margin)
        let trailingX = min(boundsRect.maxX - trailingSize.width - 1, imageRect.maxX + margin)
        let centerYForLR = max(
            boundsRect.minY + 1,
            min(boundsRect.maxY - leadingSize.height - 1, cy - (leadingSize.height * 0.5))
        )

        let topY = min(boundsRect.maxY - topSize.height - 1, imageRect.maxY + margin)
        let bottomY = max(boundsRect.minY + 1, imageRect.minY - bottomSize.height - margin)

        let topX = max(
            boundsRect.minX + 1,
            min(boundsRect.maxX - topSize.width - 1, cx - (topSize.width * 0.5))
        )
        let bottomX = max(
            boundsRect.minX + 1,
            min(boundsRect.maxX - bottomSize.width - 1, cx - (bottomSize.width * 0.5))
        )

        drawText(orientation.leading, at: NSPoint(x: leadingX, y: centerYForLR), attrs: attrs)
        drawText(orientation.trailing, at: NSPoint(x: trailingX, y: centerYForLR), attrs: attrs)
        drawText(orientation.top, at: NSPoint(x: topX, y: topY), attrs: attrs)
        drawText(orientation.bottom, at: NSPoint(x: bottomX, y: bottomY), attrs: attrs)
    }

    private func drawText(_ text: String, at point: NSPoint, attrs: [NSAttributedString.Key: Any]) {
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    /// The image's aspect-fit rect: the whole image unzoomed, and the visible
    /// window (clip + hit area) when zoomed. Zoomed drawing goes through
    /// `viewport.drawnRect(fitted:)`.
    private func imageRect() -> NSRect {
        guard let image else { return .zero }
        return aspectFitRect(for: image.size, inside: bounds)
    }

    /// Right edge of the rendered image in this canvas's own coordinates, or
    /// `nil` when nothing is drawn yet. The panel runs to the window edge but
    /// the image is alignment-positioned within it; the metadata scrubber uses
    /// this to stop at the image edge instead of the panel edge.
    var renderedImageRightEdge: CGFloat? {
        image == nil ? nil : imageRect().maxX
    }

    private func notifyCursorPosition(at location: NSPoint) {
        let imageRect = imageRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return }

        // Clamp into the visible (fitted) area, then map through the zoom: the
        // model receives the same image-normalized point it always did, so its
        // normalized-point → voxel mapping is untouched by zoom/pan.
        let clamped = ViewportPoint(
            x: Double(min(max(location.x, imageRect.minX), imageRect.maxX - 0.001)),
            y: Double(min(max(location.y, imageRect.minY), imageRect.maxY - 0.001))
        )
        guard let normalized = viewport.normalizedPoint(at: clamped, fitted: ViewportRect(imageRect)) else { return }
        onCursorPosition?(plane, MIQNormalizedPoint(x: normalized.x, y: normalized.y))
    }

    /// Back to the plain aspect-fit view ("0", double-click on a zoomed panel).
    func resetViewport() {
        viewport = .identity
    }

    private func drawCrosshair(_ crosshair: MIQNormalizedPoint, in imageRect: NSRect) {
        let x = imageRect.minX + (CGFloat(crosshair.x) * imageRect.width)
        let y = imageRect.maxY - (CGFloat(crosshair.y) * imageRect.height)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: imageRect.minY))
        path.line(to: NSPoint(x: x, y: imageRect.maxY))
        path.move(to: NSPoint(x: imageRect.minX, y: y))
        path.line(to: NSPoint(x: imageRect.maxX, y: y))
        path.lineWidth = 1.5
        path.setLineDash([5, 5], count: 2, phase: 0)

        labelColor.setStroke()
        path.stroke()
    }
}
