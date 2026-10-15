import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
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
    ///
    /// Every scene in `MIQApp.body` opts out of external events
    /// (`.handlesExternalEvents(matching: [])`), so SwiftUI doesn't also open a
    /// Settings or Brain Mask window for the file: the event lands here only.
    func application(_: NSApplication, open urls: [URL]) {
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
                ? String(localized: "MIQ can’t open “\(rejected[0].lastPathComponent)”.")
                : String(localized: "MIQ can’t open \(rejected.count) of these files.")
            alert.informativeText = String(localized: "MIQ opens NIfTI, MGH/MGZ, MRtrix MIF and NRRD volumes.")
            alert.runModal()
        }
        // No `reply(toOpenOrPrint:)` here: that reply belongs to the deprecated
        // `application(_:openFiles:)` path. For `application(_:open:)` AppKit
        // completes the Apple event itself, and an unsolicited reply is logged as
        // an error.
    }
}

// MARK: - Open in another viewer

/// A desktop viewer MIQ offers in "Open in…". Detected by bundle identifier
/// through Launch Services, with the usual app name in /Applications as a
/// fallback for builds whose identifier differs (or isn't documented).
struct KnownExternalViewer: Sendable {
    let name: String
    let bundleIdentifiers: [String]
    let applicationNames: [String]
}

/// One app the "Open in…" picker can offer.
struct ExternalViewerApp: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let url: URL
    var id: String { bundleIdentifier }
}

/// The app-only "Open in…" setting: which external viewer MIQ's file viewer
/// windows hand a volume to. Lives in the app's own `UserDefaults.standard`
/// (the extensions never read it), where a configuration profile can force it
/// like any other key.
@MainActor
enum ExternalViewerSettings {
    /// Bundle identifier of the chosen app; absent or empty = none chosen.
    static let bundleIdentifierKey = "externalViewerBundleIdentifier"

    /// Identifiers from the apps' published Info.plists where available
    /// (ITK-SNAP `org.itksnap`, MRIcroGL `com.mricro.MRIcroGL`) or app
    /// catalogues (3D Slicer `org.slicer.slicer`, Horos
    /// `org.horosproject.horos`). FSLeyes and Mango document none, so they are
    /// found by name in /Applications only.
    static let known: [KnownExternalViewer] = [
        KnownExternalViewer(name: "ITK-SNAP", bundleIdentifiers: ["org.itksnap"], applicationNames: ["ITK-SNAP"]),
        KnownExternalViewer(name: "3D Slicer", bundleIdentifiers: ["org.slicer.slicer"], applicationNames: ["Slicer"]),
        KnownExternalViewer(name: "MRIcroGL", bundleIdentifiers: ["com.mricro.MRIcroGL"], applicationNames: ["MRIcroGL"]),
        KnownExternalViewer(name: "FSLeyes", bundleIdentifiers: [], applicationNames: ["FSLeyes"]),
        KnownExternalViewer(name: "Mango", bundleIdentifiers: [], applicationNames: ["Mango"]),
        KnownExternalViewer(name: "Horos", bundleIdentifiers: ["org.horosproject.horos"], applicationNames: ["Horos"]),
    ]

    static var isManaged: Bool {
        MIQConfig.isManaged(bundleIdentifierKey, in: UserDefaults.standard)
    }

    static var selectedBundleIdentifier: String? {
        guard let value = UserDefaults.standard.string(forKey: bundleIdentifierKey), !value.isEmpty else { return nil }
        return value
    }

    /// The chosen app, if one is set and still installed.
    static var selectedApp: ExternalViewerApp? {
        selectedBundleIdentifier.flatMap(app(bundleIdentifier:))
    }

    static func app(bundleIdentifier: String) -> ExternalViewerApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return app(at: url, bundleIdentifier: bundleIdentifier)
    }

    static func app(at url: URL, bundleIdentifier: String? = nil) -> ExternalViewerApp? {
        guard let identifier = bundleIdentifier ?? Bundle(url: url)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        let trimmed = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        return ExternalViewerApp(bundleIdentifier: identifier, name: trimmed, url: url)
    }

    /// The known viewers installed on this Mac, in `known` order.
    static func installedKnownViewers() -> [ExternalViewerApp] {
        let folders = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
        var found: [ExternalViewerApp] = []
        for viewer in known {
            if let hit = viewer.bundleIdentifiers.lazy.compactMap({ app(bundleIdentifier: $0) }).first {
                found.append(hit)
                continue
            }
            search: for folder in folders {
                for name in viewer.applicationNames {
                    let candidate = folder.appendingPathComponent(name + ".app")
                    if FileManager.default.fileExists(atPath: candidate.path), let hit = app(at: candidate) {
                        found.append(hit)
                        break search
                    }
                }
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.bundleIdentifier).inserted }
    }

    /// Asks for any application ("Other App…"). `nil` when cancelled.
    static func chooseOtherApp() -> ExternalViewerApp? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an App")
        panel.message = String(localized: "Choose the app MIQ opens volumes in.")
        panel.prompt = String(localized: "Choose")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return app(at: url)
    }

    static func restoreDefault() {
        UserDefaults.standard.removeObject(forKey: bundleIdentifierKey)
    }

    /// Hands `file` to `app` through Launch Services. A failure is reported in
    /// an alert (a sheet on `window` when given).
    static func open(_ file: URL, in app: ExternalViewerApp, from window: NSWindow?) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let appName = app.name
        let fileName = file.lastPathComponent
        NSWorkspace.shared.open([file], withApplicationAt: app.url, configuration: configuration) { _, error in
            guard let error else { return }
            let reason = error.localizedDescription
            Task { @MainActor [weak window] in
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn’t open “\(fileName)” in \(appName).")
                alert.informativeText = reason
                if let window {
                    alert.beginSheetModal(for: window) { _ in }
                } else {
                    alert.runModal()
                }
            }
        }
    }
}

/// Settings › General row choosing the "Open in…" app: the installed known
/// viewers, the current custom choice, and "Other App…".
struct ExternalViewerSettingRow: View {
    @AppStorage(ExternalViewerSettings.bundleIdentifierKey, store: .standard)
    private var bundleIdentifier: String = ""
    @State private var installed: [ExternalViewerApp] = []

    /// Picker tag of "Other App…"; never a bundle identifier (those can't
    /// contain spaces).
    private static let otherTag = "other app"

    var body: some View {
        let isManaged = ExternalViewerSettings.isManaged
        VStack(alignment: .leading, spacing: 3) {
            Picker(selection: Binding(
                get: { bundleIdentifier },
                set: { newValue in
                    guard newValue == Self.otherTag else {
                        bundleIdentifier = newValue
                        return
                    }
                    // Run the open panel after the pop-up menu has closed.
                    Task { @MainActor in
                        if let app = ExternalViewerSettings.chooseOtherApp() {
                            bundleIdentifier = app.bundleIdentifier
                            refresh()
                        }
                    }
                }
            )) {
                Text("None").tag("")
                ForEach(choices) { app in
                    Text(verbatim: app.name).tag(app.bundleIdentifier)
                }
                if !bundleIdentifier.isEmpty, !choices.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                    // Chosen (or forced by a profile) but not installed here.
                    Text("\(bundleIdentifier) (not installed)").tag(bundleIdentifier)
                }
                Divider()
                Text("Other App…").tag(Self.otherTag)
            } label: {
                Text("Open volumes in")
                Text("Adds an Open in button to MIQ’s file windows. Only installed viewers are listed.")
            }
            .disabled(isManaged)
            if isManaged {
                Label("Managed by your organisation", systemImage: "building.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("An administrator set this with a configuration profile, so it can\u{2019}t be changed here.")
            }
        }
        .onAppear(perform: refresh)
    }

    /// Installed known viewers plus the current choice when it is another app.
    private var choices: [ExternalViewerApp] {
        var list = installed
        if !bundleIdentifier.isEmpty, !list.contains(where: { $0.bundleIdentifier == bundleIdentifier }),
           let app = ExternalViewerSettings.app(bundleIdentifier: bundleIdentifier) {
            list.append(app)
        }
        return list
    }

    private func refresh() {
        installed = ExternalViewerSettings.installedKnownViewers()
    }
}

/// "File › Open in <App>", sent down the responder chain to the key file
/// viewer window (`MIQFileViewerWindow.openInExternalViewer(_:)`); a no-op
/// when no viewer window is key.
struct ExternalViewerCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            ExternalViewerMenuItem()
        }
    }
}

private struct ExternalViewerMenuItem: View {
    @AppStorage(ExternalViewerSettings.bundleIdentifierKey, store: .standard)
    private var bundleIdentifier: String = ""

    var body: some View {
        Button(title) {
            _ = NSApp.sendAction(#selector(MIQFileViewerWindow.openInExternalViewer(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("o", modifiers: [.command, .option])
    }

    private var title: String {
        if !bundleIdentifier.isEmpty, let app = ExternalViewerSettings.app(bundleIdentifier: bundleIdentifier) {
            return String(localized: "Open in \(app.name)")
        }
        return String(localized: "Open in Other App…")
    }
}

/// A plain window hosting a `QLPreviewView` for one file — the cheapest real
/// viewer, since Quick Look routes the file to the MIQ preview extension.
///
/// Its toolbar has an "Open in <App>" button for the viewer chosen in
/// Settings (`ExternalViewerSettings`), with a menu of the other installed
/// viewers; the same action is "File › Open in <App>" (⌥⌘O).
@MainActor
final class MIQFileViewerWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    let url: URL
    let window: NSWindow
    private let onClose: @MainActor (MIQFileViewerWindow) -> Void
    private static let openInItemID = NSToolbarItem.Identifier("miq.viewer.openIn")
    private weak var openInItem: NSMenuToolbarItem?

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
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("MIQFileViewer"))
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.delegate = self
        window.toolbar = toolbar
        window.center()
    }

    func windowWillClose(_: Notification) {
        onClose(self)
    }

    /// The setting may have changed in Settings while this window was in the
    /// background.
    func windowDidBecomeKey(_: Notification) {
        refreshOpenInItem()
    }

    // MARK: Open in

    /// Opens the file in the chosen viewer, or asks for an app when none is
    /// chosen (a one-off choice; the setting stays as it is).
    @objc func openInExternalViewer(_: Any?) {
        if let app = ExternalViewerSettings.selectedApp {
            ExternalViewerSettings.open(url, in: app, from: window)
        } else if let app = ExternalViewerSettings.chooseOtherApp() {
            ExternalViewerSettings.open(url, in: app, from: window)
        }
    }

    @objc private func openInMenuApp(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL,
              let app = ExternalViewerSettings.app(at: appURL) else { return }
        ExternalViewerSettings.open(url, in: app, from: window)
    }

    @objc private func openInOtherApp(_: Any?) {
        guard let app = ExternalViewerSettings.chooseOtherApp() else { return }
        ExternalViewerSettings.open(url, in: app, from: window)
    }

    private func refreshOpenInItem() {
        guard let item = openInItem else { return }
        let selected = ExternalViewerSettings.selectedApp
        let title = selected.map { String(localized: "Open in \($0.name)") } ?? String(localized: "Open in…")
        item.label = title
        item.paletteLabel = String(localized: "Open in…")
        item.toolTip = title
        item.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: title)
        // With no chosen viewer, a click on the button itself shows the menu.
        item.target = self
        item.action = selected == nil ? nil : #selector(openInExternalViewer(_:))

        let menu = NSMenu()
        var apps = ExternalViewerSettings.installedKnownViewers()
        if let selected, !apps.contains(where: { $0.bundleIdentifier == selected.bundleIdentifier }) {
            apps.insert(selected, at: 0)
        }
        for app in apps {
            let entry = NSMenuItem(title: String(localized: "Open in \(app.name)"),
                                   action: #selector(openInMenuApp(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = app.url
            menu.addItem(entry)
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: String(localized: "Other App…"),
                               action: #selector(openInOtherApp(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        item.menu = menu
    }

    func toolbar(_: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.openInItemID else { return nil }
        let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
        item.showsIndicator = true
        openInItem = item
        refreshOpenInItem()
        return item
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.openInItemID]
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.openInItemID]
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
        // Files opened from Finder ("Open With", double-click, drag onto the
        // Dock icon) are handled by `AppDelegate.application(_:open:)` in their
        // own Quick Look windows. Without this, SwiftUI's external-event routing
        // also creates a new instance of the first scene that has no
        // `handlesExternalEvents` modifier — a stray Settings window per file,
        // even when the app was launched only to open one. An empty set never
        // matches, so no scene is created for those events. Normal launches and
        // Dock reopen don't go through this routing and still show Settings.
        .handlesExternalEvents(matching: [])
        .commands {
            // The conventional slot for this item, directly under "About MIQ".
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            ExternalViewerCommands()
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
