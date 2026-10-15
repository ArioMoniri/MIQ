import AppKit
import QuickLookUI
import SwiftUI
import MIQCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Viewer windows opened from Finder ("Open With" / double-click), kept alive
    /// until the user closes them.
    private var viewerWindows: [MIQFileViewerWindow] = []

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// Files handed over by Launch Services via the `CFBundleDocumentTypes` claim
    /// in Info.plist. Each recognised volume opens in its own Quick Look window,
    /// so the MIQ preview extension renders it exactly as on Space in Finder.
    /// A `.gz` that isn't a volume (the gzip claim is broad) is declined.
    func application(_ application: NSApplication, open urls: [URL]) {
        let volumes = urls.filter { MIQFileKind(url: $0) != nil }
        for url in volumes {
            if let existing = viewerWindows.first(where: { $0.url == url }) {
                existing.window.makeKeyAndOrderFront(nil)
                continue
            }
            guard let viewer = MIQFileViewerWindow(url: url, onClose: { [weak self] closed in
                self?.viewerWindows.removeAll { $0 === closed }
            }) else { continue }
            viewerWindows.append(viewer)
            viewer.window.makeKeyAndOrderFront(nil)
        }
        if !volumes.isEmpty {
            NSApp.activate()
        }

        let rejected = urls.filter { MIQFileKind(url: $0) == nil }
        if !rejected.isEmpty {
            let alert = NSAlert()
            alert.messageText = rejected.count == 1
                ? "MIQ can’t open “\(rejected[0].lastPathComponent)”."
                : "MIQ can’t open \(rejected.count) of these files."
            alert.informativeText = "MIQ opens NIfTI, MGH/MGZ, MRtrix MIF and NRRD volumes."
            alert.runModal()
        }
        application.reply(toOpenOrPrint: rejected.isEmpty ? .success : .failure)
    }
}

/// A plain window hosting a `QLPreviewView` for one file — the cheapest real
/// viewer, since Quick Look routes the file to the MIQ preview extension.
@MainActor
final class MIQFileViewerWindow: NSObject, NSWindowDelegate {
    let url: URL
    let window: NSWindow
    private let onClose: @MainActor (MIQFileViewerWindow) -> Void

    init?(url: URL, onClose: @escaping @MainActor (MIQFileViewerWindow) -> Void) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        // Typed optional so this compiles whether the SDK imports the
        // initializer as failable or not.
        let previewView: QLPreviewView? = QLPreviewView(frame: frame, style: .normal)
        guard let previewView else { return nil }
        previewView.autostarts = true
        previewView.shouldCloseWithWindow = true
        previewView.previewItem = url as NSURL

        self.url = url
        self.onClose = onClose
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.title = url.lastPathComponent
        window.representedURL = url
        window.contentView = previewView
        window.contentMinSize = NSSize(width: 320, height: 240)
        window.delegate = self
        window.center()
    }

    func windowWillClose(_: Notification) {
        onClose(self)
    }
}

@main
struct MIQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Owned here rather than in ContentView so the updater starts with the app,
    // not with the Settings window, and survives that window closing.
    @StateObject private var updater = UpdaterController()

    #if DEBUG
    private static let appGroupStore = UserDefaults(suiteName: MIQConfig.appGroupID)
    @AppStorage(MIQConfig.Keys.debugShowLayoutBorders, store: Self.appGroupStore) private var debugShowLayoutBorders = false
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(updater)
        }
        .defaultSize(width: 640, height: 550)
        .windowResizability(.contentSize)
        .commands {
            // The conventional slot for this item, directly under "About MIQ".
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            BrainMaskCommands()
            #if DEBUG
            CommandMenu("Debug") {
                Toggle("Show layout borders in preview", isOn: $debugShowLayoutBorders)
            }
            #endif
        }

        // Tools → Brain Mask… (app only; see BrainMaskTool.swift).
        BrainMaskWindowScene()
    }
}
