import AppKit
import MIQCore

/// The fourth-quadrant tile for the alternate views (MIP / MinIP / 3D). Shows
/// the renderer's image aspect-fit, a caption, and a progress indicator while
/// work runs. In 3D, drag rotates and scroll / pinch zoom; in every mode a
/// double-click maximises and a secondary click opens the context menu.
final class MIQAlternateViewTile: NSView {
    var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    var caption: String = "" {
        didSet {
            guard caption != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel(caption)
        }
    }
    var placeholder: String? { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var smoothsImage = false { didSet { if smoothsImage != oldValue { needsDisplay = true } } }
    var labelColor: NSColor = .white { didSet { needsDisplay = true } }
    /// Drag / scroll drive the 3D camera only in 3D mode.
    var isInteractive3D = false
    var isBusy = false { didSet { if isBusy != oldValue { updateBusyIndicator() } } }

    var onDoubleClick: (@MainActor () -> Void)?
    var onRotate: (@MainActor (CGFloat, CGFloat) -> Void)?
    var onZoom: (@MainActor (CGFloat) -> Void)?
    var onContextMenu: (@MainActor (NSEvent) -> Void)?
    var onActivate: (@MainActor () -> Void)?

    private let spinner = NSProgressIndicator()
    private let busyLabel = NSTextField(labelWithString: String(localized: "Computing…", table: "Preview"))
    private var lastDragLocation: NSPoint?
    private var secondaryDragged = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        busyLabel.font = .systemFont(ofSize: 11)
        busyLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        busyLabel.translatesAutoresizingMaskIntoConstraints = false
        busyLabel.isHidden = true
        addSubview(spinner)
        addSubview(busyLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            busyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            busyLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder _: NSCoder) {
        return nil
    }

    /// Reduce Motion: no spinning indicator, the static "Computing…" text alone.
    private func updateBusyIndicator() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        busyLabel.isHidden = !isBusy
        if isBusy, !reduceMotion {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func draw(_: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            let rect = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
            let context = NSGraphicsContext.current
            let previous = context?.imageInterpolation
            context?.imageInterpolation = smoothsImage ? .high : .none
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            if let previous { context?.imageInterpolation = previous }
        } else if let placeholder, !isBusy {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1),
            ]
            let size = (placeholder as NSString).size(withAttributes: attrs)
            (placeholder as NSString).draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attrs
            )
        }

        if !caption.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: labelColor,
            ]
            (caption as NSString).draw(at: NSPoint(x: 6, y: bounds.maxY - 18), withAttributes: attrs)
        }
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if event.modifierFlags.contains(.control) {
            onContextMenu?(event)
            return
        }
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        lastDragLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive3D, let last = lastDragLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        onRotate?(location.x - last.x, location.y - last.y)
        lastDragLocation = location
    }

    override func mouseUp(with _: NSEvent) {
        lastDragLocation = nil
    }

    override func rightMouseDown(with _: NSEvent) {
        secondaryDragged = false
    }

    override func rightMouseDragged(with _: NSEvent) {
        secondaryDragged = true
    }

    override func rightMouseUp(with event: NSEvent) {
        guard !secondaryDragged else { return }
        onContextMenu?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInteractive3D else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let perPoint = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        onZoom?(CGFloat(exp(Double(delta) * perPoint)))
    }

    override func magnify(with event: NSEvent) {
        guard isInteractive3D else { return }
        onZoom?(1 + event.magnification)
    }
}
