import Foundation
import Testing
@testable import MIQCore

struct ViewportTransformTests {
    let fitted = ViewportRect(x: 10, y: 20, width: 200, height: 100)

    private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

    @Test func identityDrawsTheFittedRect() {
        let t = ViewportTransform.identity
        #expect(t.isIdentity)
        #expect(t.drawnRect(fitted: fitted) == fitted)
        let p = t.normalizedPoint(at: ViewportPoint(x: 10, y: 119.999), fitted: fitted)
        #expect(p != nil)
        #expect(near(p!.x, 0) && near(p!.y, 0, 1e-4))   // top-left (y up in view ⇒ y down normalized)
    }

    @Test func centerIsForcedToMiddleAtUnitZoom() {
        let t = ViewportTransform(zoom: 1, centerX: 0.9, centerY: 0.1)
        #expect(t.centerX == 0.5 && t.centerY == 0.5)
    }

    @Test func zoomIsClamped() {
        #expect(ViewportTransform(zoom: 0.2).zoom == ViewportTransform.minZoom)
        #expect(ViewportTransform(zoom: 1000).zoom == ViewportTransform.maxZoom)
        #expect(ViewportTransform(zoom: .nan).zoom == 1)
    }

    @Test func zoomKeepsThePointUnderTheAnchorFixed() {
        let anchor = ViewportPoint(x: 60, y: 90)
        let before = ViewportTransform.identity.normalizedPoint(at: anchor, fitted: fitted)!
        let z = ViewportTransform.identity.zoomed(by: 2, anchor: anchor, fitted: fitted)
        #expect(near(z.zoom, 2))
        let after = z.normalizedPoint(at: anchor, fitted: fitted)!
        #expect(near(before.x, after.x) && near(before.y, after.y))
        // And a second zoom step about the same anchor.
        let z2 = z.zoomed(by: 1.5, anchor: anchor, fitted: fitted)
        let after2 = z2.normalizedPoint(at: anchor, fitted: fitted)!
        #expect(near(before.x, after2.x) && near(before.y, after2.y))
    }

    @Test func zoomNearTheEdgeClampsInsteadOfOpeningMargins() {
        // Anchor at the very left edge: zooming must not reveal space left of the image.
        let z = ViewportTransform.identity.zoomed(by: 4, anchor: ViewportPoint(x: 10, y: 70), fitted: fitted)
        let drawn = z.drawnRect(fitted: fitted)
        #expect(drawn.minX <= fitted.minX + 1e-9)
        #expect(drawn.maxX >= fitted.maxX - 1e-9)
        #expect(drawn.minY <= fitted.minY + 1e-9)
        #expect(drawn.maxY >= fitted.maxY - 1e-9)
    }

    @Test func zoomingBackOutReturnsToIdentity() {
        let z = ViewportTransform.identity.zoomed(by: 3, anchor: ViewportPoint(x: 30, y: 30), fitted: fitted)
        let back = z.zoomed(by: 1.0 / 3.0, anchor: ViewportPoint(x: 200, y: 100), fitted: fitted)
        #expect(back.isIdentity)
        #expect(back.drawnRect(fitted: fitted) == fitted)
    }

    @Test func panFollowsThePointerAndClamps() {
        let z = ViewportTransform(zoom: 4)
        let anchor = ViewportPoint(x: 110, y: 70)  // fitted centre
        let before = z.normalizedPoint(at: anchor, fitted: fitted)!
        // Drag right by 20 and up by 10: the image moves with the pointer, so the
        // point that was under the anchor is now at anchor + delta.
        let p = z.panned(dx: 20, dy: 10, fitted: fitted)
        let moved = p.normalizedPoint(at: ViewportPoint(x: 130, y: 80), fitted: fitted)!
        #expect(near(before.x, moved.x) && near(before.y, moved.y))
        // A huge drag stops at the image edge.
        let far = z.panned(dx: 1e6, dy: -1e6, fitted: fitted)
        #expect(near(far.centerX, 0.5 / 4))
        #expect(near(far.centerY, 0.5 / 4))
        // Panning does nothing at unit zoom.
        #expect(ViewportTransform.identity.panned(dx: 50, dy: 50, fitted: fitted).isIdentity)
    }

    @Test func viewPointRoundTrips() {
        let z = ViewportTransform(zoom: 2.5, centerX: 0.3, centerY: 0.7)
        let n = ViewportPoint(x: 0.31, y: 0.66)
        let v = z.viewPoint(forNormalized: n, fitted: fitted)
        let back = z.normalizedPoint(at: v, fitted: fitted)!
        #expect(near(back.x, n.x) && near(back.y, n.y))
    }

    @Test func pointsOutsideTheFittedRectMapToNil() {
        let z = ViewportTransform(zoom: 2)
        #expect(z.normalizedPoint(at: ViewportPoint(x: 5, y: 50), fitted: fitted) == nil)
        #expect(z.normalizedPoint(at: ViewportPoint(x: 50, y: 121), fitted: fitted) == nil)
    }

    @Test func visibleRegionShrinksWithZoom() {
        let r = ViewportTransform(zoom: 4, centerX: 0.5, centerY: 0.5).visibleNormalizedRegion
        #expect(near(r.x0, 0.375) && near(r.x1, 0.625) && near(r.y0, 0.375) && near(r.y1, 0.625))
    }

    /// Cursor → voxel under zoom: the pixel under the pointer agrees with the
    /// model's normalized-point → voxel rule (`MIQVolume.cursor`).
    @Test func pixelUnderZoomMatchesVolumeCursorMapping() {
        let volume = makeVolume(width: 8, height: 6, depth: 4)
        let options = RenderingOptions(lowerPercentile: 0, upperPercentile: 100, orientation: .stored, segmentationColoring: .off)
        let geometry = volume.sliceGeometry(for: .axial, options: options)
        let fittedRect = ViewportRect(x: 0, y: 0, width: Double(geometry.width) * 10, height: Double(geometry.height) * 10)
        let z = ViewportTransform(zoom: 2, centerX: 0.25, centerY: 0.75)
        // Centre of the visible area: the image position (0.25, 0.75).
        let point = ViewportPoint(x: fittedRect.midX + 0.01, y: fittedRect.midY - 0.01)
        let pixel = z.pixel(at: point, fitted: fittedRect, width: geometry.width, height: geometry.height)!
        #expect(pixel.column == Int(0.25 * Double(geometry.width)))
        #expect(pixel.row == Int(0.75 * Double(geometry.height)))
        let normalized = z.normalizedPoint(at: point, fitted: fittedRect)!
        let cursor = volume.cursor(
            for: .axial, sliceIndex: 1,
            normalizedPoint: MIQNormalizedPoint(x: normalized.x, y: normalized.y),
            options: options
        )
        let column = geometry.horizontalReversed ? geometry.width - 1 - pixel.column : pixel.column
        let row = geometry.verticalReversed ? geometry.height - 1 - pixel.row : pixel.row
        #expect(cursor.coordinate(forAxis: geometry.horizontalAxis) == column)
        #expect(cursor.coordinate(forAxis: geometry.verticalAxis) == row)
    }

    private func makeVolume(width: Int, height: Int, depth: Int) -> MIQVolume {
        let header = MIQHeader(
            littleEndian: true,
            dimensions: [width, height, depth, 1],
            pixdim: [1, 1, 1, 1, 1],
            datatype: .uint8,
            voxOffset: 0,
            sclSlope: 1,
            sclInter: 0,
            qformCode: 0,
            sformCode: 0,
            srowX: [1, 0, 0, 0],
            srowY: [0, 1, 0, 0],
            srowZ: [0, 0, 1, 0]
        )
        let data = Data((0..<(width * height * depth)).map { UInt8($0 % 251) })
        return MIQVolume(image: MIQImage(header: header, storage: data, payloadOffset: 0))
    }
}

struct PreviewLayoutStateTests {
    @Test func doubleClickMaximisesAndRestores() {
        var s = PreviewLayoutState()
        #expect(s.handleDoubleClick(on: .axial, isZoomed: false) == .maximized(.axial))
        #expect(s.isVisible(.axial) && !s.isVisible(.coronal))
        #expect(s.handleDoubleClick(on: .axial, isZoomed: false) == .restored)
        #expect(s.maximized == nil)
        #expect(PreviewPanel.allCases.allSatisfy(s.isVisible))
    }

    @Test func doubleClickOnZoomedPanelResetsZoomFirst() {
        var s = PreviewLayoutState()
        _ = s.toggleMaximize(.coronal)
        #expect(s.handleDoubleClick(on: .coronal, isZoomed: true) == .resetZoom)
        #expect(s.maximized == .coronal)
    }

    @Test func metadataQuadrantIsNeverMaximised() {
        var s = PreviewLayoutState()
        #expect(s.toggleMaximize(.auxiliary) == nil)
        #expect(s.maximized == nil)
        s.setViewMode(.volume3D)
        #expect(s.toggleMaximize(.auxiliary) == .maximized(.auxiliary))
        // Returning to metadata restores the layout.
        s.setViewMode(.slices)
        #expect(s.maximized == nil)
    }

    @Test func viewModeCycleWraps() {
        var s = PreviewLayoutState()
        let all = PreviewViewMode.available(isRGB: false, allows3D: true)
        #expect(all == [.slices, .mip, .minip, .volume3D])
        var seen: [PreviewViewMode] = []
        for _ in 0..<4 {
            s.cycleViewMode(available: all)
            seen.append(s.viewMode)
        }
        #expect(seen == [.mip, .minip, .volume3D, .slices])
        #expect(PreviewViewMode.available(isRGB: true, allows3D: true) == [.slices])
        #expect(!PreviewViewMode.available(isRGB: false, allows3D: false).contains(.volume3D))
    }

    @Test func metadataToggleRemembersLastAlternate() {
        var s = PreviewLayoutState()
        let all = PreviewViewMode.available(isRGB: false, allows3D: true)
        s.toggleMetadata(available: all)
        #expect(s.viewMode == .mip)
        s.setViewMode(.volume3D)
        s.toggleMetadata(available: all)
        #expect(s.viewMode == .slices)
        s.toggleMetadata(available: all)
        #expect(s.viewMode == .volume3D)
        // Unavailable remembered mode falls back to the first alternate.
        var t = PreviewLayoutState(viewMode: .volume3D)
        t.setViewMode(.slices)
        t.toggleMetadata(available: [.slices, .mip, .minip])
        #expect(t.viewMode == .mip)
        // Nothing to toggle to for RGB.
        var r = PreviewLayoutState()
        r.toggleMetadata(available: [.slices])
        #expect(r.viewMode == .slices)
    }

    @Test func viewModeProjectionMapping() {
        #expect(PreviewViewMode.mip.projectionMode == .mip)
        #expect(PreviewViewMode.minip.projectionMode == .minip)
        #expect(PreviewViewMode.volume3D.projectionMode == nil)
        #expect(PreviewPanel(plane: .sagittal).plane == .sagittal)
        #expect(PreviewPanel.auxiliary.plane == nil)
    }
}

struct WindowPresetShortcutTests {
    @Test func digitsMapToFixedPresets() {
        #expect(WindowPresetShortcuts.preset(forDigit: 1) == .brain)
        #expect(WindowPresetShortcuts.preset(forDigit: 4) == .bone)
        #expect(WindowPresetShortcuts.preset(forDigit: 6) == .softTissue)
        #expect(WindowPresetShortcuts.preset(forDigit: 0) == nil)
        #expect(WindowPresetShortcuts.preset(forDigit: 7) == nil)
        for preset in WindowPreset.fixedPresets {
            let digit = WindowPresetShortcuts.digit(for: preset)!
            #expect(WindowPresetShortcuts.preset(forDigit: digit) == preset)
        }
        #expect(WindowPresetShortcuts.digit(for: .auto) == nil)
    }

    @Test func cycleVisitsEveryPresetAndWraps() {
        var p = WindowPreset.auto
        var visited: [WindowPreset] = []
        for _ in WindowPreset.allCases {
            p = WindowPresetShortcuts.next(after: p)
            visited.append(p)
        }
        #expect(visited.last == .auto)
        #expect(Set(visited) == Set(WindowPreset.allCases))
    }

    @Test func initialPresetNeedsCTAutoDetectAndAFixedPreset() {
        #expect(WindowPresetShortcuts.initialPreset(looksLikeCT: true, autoDetect: true, configured: .brain) == .brain)
        #expect(WindowPresetShortcuts.initialPreset(looksLikeCT: false, autoDetect: true, configured: .brain) == nil)
        #expect(WindowPresetShortcuts.initialPreset(looksLikeCT: true, autoDetect: false, configured: .brain) == nil)
        #expect(WindowPresetShortcuts.initialPreset(looksLikeCT: true, autoDetect: true, configured: .auto) == nil)
    }

    @Test func badgeText() {
        let b = WindowPreset.brain.bounds!
        #expect(WindowPresetShortcuts.badgeText(preset: .brain, bounds: b) == "Brain · W 80 / L 40")
        #expect(WindowPresetShortcuts.badgeText(preset: nil, bounds: b) == "W 80 / L 40")
        #expect(WindowPresetShortcuts.badgeText(preset: .auto, bounds: b) == "W 80 / L 40")
    }
}

struct ColormapCycleTests {
    @Test func standardCycleWraps() {
        let options = ColormapCycle.options(suggested: .grayscale)
        #expect(options == [.grayscale, .hot, .viridis, .inferno])
        #expect(ColormapCycle.next(after: .inferno, in: options) == .grayscale)
        #expect(ColormapCycle.next(after: .grayscale, in: options) == .hot)
        // A map not in the list restarts at the first entry.
        #expect(ColormapCycle.next(after: .winter, in: options) == .grayscale)
    }

    @Test func divergingIsOfferedForSignedStatistics() {
        let suggested = Colormap.suggested(intentCode: 5, minValue: -4, maxValue: 6, isFloatingPoint: true)
        let options = ColormapCycle.options(suggested: suggested)
        #expect(options == [.grayscale, .diverging, .hot, .viridis, .inferno])
        #expect(ColormapCycle.displayName(.diverging) == "Diverging")
    }
}

struct VolumeCameraInteractionTests {
    @Test func dragRotatesAndClampsElevation() {
        let c = VolumeRenderCamera.anterior.rotated(dragX: 100, dragY: 40)
        #expect(c.azimuth == 50)
        #expect(c.elevation == 20)
        let top = c.rotated(dragX: 0, dragY: 10_000)
        #expect(top.elevation == VolumeRenderCamera.maxElevation)
        let bottom = c.rotated(dragX: 0, dragY: -10_000)
        #expect(bottom.elevation == -VolumeRenderCamera.maxElevation)
    }

    @Test func azimuthWraps() {
        let c = VolumeRenderCamera(azimuth: 170).rotated(dragX: 40, dragY: 0)
        #expect(c.azimuth == -170)
        let d = VolumeRenderCamera(azimuth: -170).rotated(dragX: -40, dragY: 0)
        #expect(d.azimuth == 170)
        let e = VolumeRenderCamera().rotated(dragX: 360 * 2 * 3, dragY: 0)
        #expect(abs(e.azimuth) < 1e-3)
    }

    @Test func zoomClamps() {
        #expect(VolumeRenderCamera().zoomed(by: 100).zoom == VolumeRenderCamera.zoomRange.upperBound)
        #expect(VolumeRenderCamera().zoomed(by: 0.001).zoom == VolumeRenderCamera.zoomRange.lowerBound)
        #expect(VolumeRenderCamera().zoomed(by: -1).zoom == 1)
    }

    @Test func modeCycle() {
        #expect(VolumeRenderModeCycle.available(isLabelVolume: true) == [.labels])
        #expect(VolumeRenderModeCycle.next(after: .mip, isLabelVolume: false) == .dvr)
        #expect(VolumeRenderModeCycle.next(after: .dvr, isLabelVolume: false) == .mip)
        #expect(VolumeRenderModeCycle.next(after: .mip, isLabelVolume: true) == .labels)
    }
}

struct PreviewAccessibilityTests {
    @Test func sliceLabel() {
        #expect(PreviewAccessibility.sliceLabel(plane: .axial, sliceIndex: 44, sliceCount: 90, window: "W 80 / L 40")
                == "Axial slice 45 of 90, window W 80 / L 40")
        #expect(PreviewAccessibility.sliceLabel(plane: .coronal, sliceIndex: 0, sliceCount: 1, window: nil)
                == "Coronal slice 1 of 1")
        #expect(PreviewAccessibility.sliceLabel(plane: .sagittal, sliceIndex: 500, sliceCount: 10, window: "")
                == "Sagittal slice 10 of 10")
    }

    @Test func volumeValue() {
        #expect(PreviewAccessibility.volumeValue(index: 2, count: 20) == "Volume 3 of 20")
        #expect(PreviewAccessibility.volumeValue(index: -5, count: 0) == "Volume 1 of 1")
    }
}

struct PreviewWindowSizingTests {
    @Test func isotropicCubeIsSquare() {
        let s = PreviewWindowSizing.preferredSize(coronalWidth: 256, coronalHeight: 256, sagittalWidth: 256, axialHeight: 256)
        #expect(s.width == 640 && s.height == 640)
    }

    @Test func wideFieldOfViewWidensTheWindowWithinLimits() {
        let s = PreviewWindowSizing.preferredSize(coronalWidth: 512, coronalHeight: 200, sagittalWidth: 512, axialHeight: 512)
        #expect(s.width > 640)
        #expect(s.width <= PreviewWindowSizing.maxWidth)
        #expect(s.height >= PreviewWindowSizing.minHeight && s.height <= PreviewWindowSizing.maxHeight)
        let extreme = PreviewWindowSizing.preferredSize(coronalWidth: 4000, coronalHeight: 10, sagittalWidth: 10, axialHeight: 10)
        #expect(extreme.width == PreviewWindowSizing.maxWidth)
        let tall = PreviewWindowSizing.preferredSize(coronalWidth: 10, coronalHeight: 4000, sagittalWidth: 10, axialHeight: 10)
        #expect(tall.width == PreviewWindowSizing.minWidth)
        #expect(tall.height <= PreviewWindowSizing.maxHeight)
    }

    @Test func degenerateInputFallsBack() {
        let s = PreviewWindowSizing.preferredSize(coronalWidth: 0, coronalHeight: 1, sagittalWidth: 1, axialHeight: 1)
        #expect(s.width == PreviewWindowSizing.fallback.width && s.height == PreviewWindowSizing.fallback.height)
        let n = PreviewWindowSizing.preferredSize(coronalWidth: .nan, coronalHeight: 1, sagittalWidth: 1, axialHeight: 1)
        #expect(n.width == PreviewWindowSizing.fallback.width)
    }
}
