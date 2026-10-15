import AppKit
import SwiftUI
import MIQCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - "Describe file" (opt-in, app-only)
//
// Writes a one-sentence *technical* caption of a volume — likely modality,
// matrix, resolution, coverage — with a language model that runs on this Mac:
// Apple's on-device Foundation Models (macOS 26+), or a user-configured
// OpenAI-compatible server on a loopback address (e.g. llama.cpp's
// `llama-server`). It is OFF by default and lives only in the app target; the
// Quick Look and thumbnail extensions never compile this file.
//
// Keeping MIQ outside the medical-device definition is the reason for every
// guard here (see the doc comment on `CaptionPrompt` for the FDA Jan 2026 CDS
// guidance rationale): the model only ever sees allowlisted header facts, its
// instructions forbid findings and diagnosis, its answer passes through
// `CaptionPrompt.filterOutput` (diagnostic vocabulary → neutral header
// summary), and the panel permanently shows "Generated on-device. Not a medical
// interpretation." The local-server engine re-validates the endpoint with
// `LocalEndpointPolicy` on every request and refuses redirects, so no request
// can leave the loopback interface.

/// Settings keys for the caption feature. Stored in the app's own
/// `UserDefaults.standard`, not the shared app group: the extensions have no
/// use for them, and keeping them out of the group keeps the feature app-only.
enum CaptionSettings {
    static var store: UserDefaults { .standard }

    enum Keys {
        /// Master opt-in. While `false` the panel's button is disabled.
        static let enabled = "captionFeatureEnabled"
        /// `CaptionEngineKind.rawValue`.
        static let engine = "captionEngine"
        /// Base URL of the local OpenAI-compatible server.
        static let endpointURL = "captionLocalEndpointURL"
        /// `model` field sent to the local server (llama.cpp ignores it).
        static let endpointModel = "captionLocalEndpointModel"
        /// Also send a downsampled axial centre slice (multimodal models only).
        static let includeSliceImage = "captionIncludeSliceImage"
    }

    enum Defaults {
        static let enabled = false
        static let engine = CaptionEngineKind.onDevice.rawValue
        static let endpointURL = LocalEndpointPolicy.defaultEndpoint
        static let endpointModel = ""
        static let includeSliceImage = false
    }

    /// Whether a configuration profile forces the master opt-in (in the app's
    /// own preference domain). The Settings toggle is then disabled.
    static var enabledIsManaged: Bool {
        MIQConfig.isManaged(Keys.enabled, in: store)
    }

    /// "Reset All Settings…": drops every stored caption setting (managed
    /// values are unaffected — they live in a layer above).
    static func restoreDefaults() {
        for key in [Keys.enabled, Keys.engine, Keys.endpointURL, Keys.endpointModel, Keys.includeSliceImage] {
            store.removeObject(forKey: key)
        }
    }
}

enum CaptionEngineKind: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    case localEndpoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice:      return String(localized: "Apple on-device model")
        case .localEndpoint: return String(localized: "Local server (OpenAI-compatible)")
        }
    }
}

enum CaptionError: LocalizedError {
    case unreadableFile
    case onDeviceUnsupported
    case onDeviceUnavailable(String)
    case endpointRejected(LocalEndpointPolicy.Rejection)
    case endpointHTTPStatus(Int)
    case endpointMalformedResponse

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return String(localized: "The file's header could not be read.")
        case .onDeviceUnsupported:
            return String(localized: "The on-device model requires macOS 26 or later with Apple Intelligence.")
        case .onDeviceUnavailable(let reason):
            return String(localized: "The on-device model is not available (\(reason)).")
        case .endpointRejected(let rejection):
            switch rejection {
            case .nonLoopbackHost:
                return String(localized: "Only local servers are allowed: use 127.0.0.1, localhost or [::1].")
            case .unsupportedScheme:
                return String(localized: "The server URL must start with http:// or https://.")
            case .credentialsNotAllowed:
                return String(localized: "The server URL must not contain a user name or password.")
            case .malformed:
                return String(localized: "The server URL is not valid.")
            }
        case .endpointHTTPStatus(let status):
            return String(localized: "The local server returned HTTP \(status).")
        case .endpointMalformedResponse:
            return String(localized: "The local server's reply was not an OpenAI-compatible chat completion.")
        }
    }
}

// MARK: - Input

/// What an engine is given: the allowlisted header facts and, only when the
/// user opted in, one downsampled axial centre slice. Never the file name.
struct CaptionInput: Sendable {
    let metadata: [String: String]
    let slice: RGBABitmap?

    /// Reads the header facts off the MainActor.
    ///
    /// Without a slice this is header-only (`CaptionPrompt.headerOnlyMetadata`):
    /// the voxel payload is never read or decompressed, so a multi-GB `.nii.gz`
    /// is described in milliseconds. Only kinds without a bounded header (Zarr,
    /// DICOM) — and the opt-in slice image — fall back to the full parse.
    ///
    /// The work runs detached but stays tied to the caller's cancellation
    /// (`withCancellableDetachedWork`), so `CaptionModel.reset()` — a new file,
    /// the panel closing — stops a parse that is still decoding.
    static func make(fileURL: URL, includeSlice: Bool) async throws -> CaptionInput {
        try await withCancellableDetachedWork(priority: .userInitiated) {
            if !includeSlice, let metadata = try? CaptionPrompt.headerOnlyMetadata(url: fileURL) {
                return CaptionInput(metadata: metadata, slice: nil)
            }
            try Task.checkCancellation()
            let kind = MIQFileKind(url: fileURL)
            let image: MIQImage
            do {
                image = try MIQParser().parse(url: fileURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CaptionError.unreadableFile
            }
            try Task.checkCancellation()
            let volume = MIQVolume(image: image)
            let header = image.header
            let metadata = CaptionPrompt.metadata(
                header: header,
                format: header.formatLabel ?? kind?.displayName,
                orientation: volume.storageOrientationLabel()
            )
            var slice: RGBABitmap?
            if includeSlice {
                let options = RenderingOptions(
                    lowerPercentile: MIQConfig.Defaults.windowLowerPercentile,
                    upperPercentile: MIQConfig.Defaults.windowUpperPercentile,
                    orientation: .stored,
                    segmentationColoring: .off
                )
                slice = volume.centerSlice(plane: .axial, maxDimension: 384, options: options).rgbaBitmap()
            }
            return CaptionInput(metadata: metadata, slice: slice)
        }
    }

    var sliceCGImage: CGImage? {
        guard let slice, slice.width > 0, slice.height > 0,
              slice.pixels.count == slice.width * slice.height * 4,
              let provider = CGDataProvider(data: slice.pixels as CFData) else { return nil }
        return CGImage(
            width: slice.width, height: slice.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: slice.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    var slicePNG: Data? {
        guard let cgImage = sliceCGImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

// MARK: - Engines

protocol CaptionEngine: Sendable {
    /// The model's unfiltered answer. Callers must pass it through
    /// `CaptionPrompt.filterOutput` before showing it.
    func rawCaption(for input: CaptionInput) async throws -> String
}

#if canImport(FoundationModels)
/// Apple's on-device system model. Text-only on macOS 26. Image input uses
/// `Attachment` (documented for macOS 27 in "Analyzing images with multimodal
/// prompting"); because that type does not exist in the macOS 26 SDK, the
/// image path is additionally compiled only when the build defines
/// `MIQ_FM_IMAGE_ATTACHMENTS` (add it to SWIFT_ACTIVE_COMPILATION_CONDITIONS
/// once the project builds with the macOS 27 SDK).
@available(macOS 26, *)
struct OnDeviceCaptionEngine: CaptionEngine {
    func rawCaption(for input: CaptionInput) async throws -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw CaptionError.onDeviceUnavailable(String(describing: reason))
        }

        let session = LanguageModelSession(model: model, instructions: CaptionPrompt.systemInstructions)
        let options = GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: 96)
        let prompt = CaptionPrompt.userPrompt(metadata: input.metadata)

        #if MIQ_FM_IMAGE_ATTACHMENTS
        if #available(macOS 27, *), let image = input.sliceCGImage {
            let response = try await session.respond(options: options) {
                prompt
                Attachment(image)
            }
            return response.content
        }
        #endif

        return try await session.respond(to: prompt, options: options).content
    }
}
#endif

/// Refuses every HTTP redirect, so a loopback server cannot bounce the request
/// (and the header facts in it) to another host.
private final class RefuseRedirectsDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// A user-run OpenAI-compatible `/v1/chat/completions` server on loopback,
/// e.g. `llama-server -m medgemma-1.5-4b-it-Q4_K_M.gguf --mmproj … --port 8080`.
struct LocalEndpointCaptionEngine: CaptionEngine {
    let endpoint: String
    let model: String

    func rawCaption(for input: CaptionInput) async throws -> String {
        // Validated here, at request time, not only when the setting is typed.
        let base: URL
        switch LocalEndpointPolicy.validate(endpoint) {
        case .success(let url): base = url
        case .failure(let rejection): throw CaptionError.endpointRejected(rejection)
        }
        let url = LocalEndpointPolicy.chatCompletionsURL(base: base)
        guard LocalEndpointPolicy.isAllowedRedirect(to: url) else {
            throw CaptionError.endpointRejected(.nonLoopbackHost)
        }

        let prompt = CaptionPrompt.userPrompt(metadata: input.metadata)
        let userContent: Any
        if let png = input.slicePNG {
            userContent = [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]],
            ]
        } else {
            userContent = prompt
        }
        let body: [String: Any] = [
            "model": model.isEmpty ? "local" : model,
            "messages": [
                ["role": "system", "content": CaptionPrompt.systemInstructions],
                ["role": "user", "content": userContent],
            ],
            "temperature": 0,
            "max_tokens": 96,
            "stream": false,
        ]

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]   // never route through a system proxy
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: RefuseRedirectsDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CaptionError.endpointMalformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw CaptionError.endpointHTTPStatus(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CaptionError.endpointMalformedResponse
        }
        return content
    }
}

// MARK: - Model

@MainActor
final class CaptionModel: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case finished(CaptionPrompt.FilteredCaption)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Reads the settings at call time, so a change in Settings applies to the
    /// next request without re-creating the panel.
    func describe(fileURL: URL) {
        let defaults = CaptionSettings.store
        guard defaults.object(forKey: CaptionSettings.Keys.enabled) as? Bool ?? CaptionSettings.Defaults.enabled else {
            return
        }
        let kind = CaptionEngineKind(rawValue: defaults.string(forKey: CaptionSettings.Keys.engine) ?? "") ?? .onDevice
        let includeSlice = defaults.object(forKey: CaptionSettings.Keys.includeSliceImage) as? Bool
            ?? CaptionSettings.Defaults.includeSliceImage
        let endpoint = defaults.string(forKey: CaptionSettings.Keys.endpointURL) ?? CaptionSettings.Defaults.endpointURL
        let endpointModel = defaults.string(forKey: CaptionSettings.Keys.endpointModel) ?? CaptionSettings.Defaults.endpointModel

        task?.cancel()
        state = .running
        task = Task { [weak self] in
            let outcome: State
            do {
                let engine = try Self.engine(kind: kind, endpoint: endpoint, model: endpointModel)
                let input = try await CaptionInput.make(fileURL: fileURL, includeSlice: includeSlice)
                let raw = try await engine.rawCaption(for: input)
                outcome = .finished(CaptionPrompt.filterOutput(raw, metadata: input.metadata))
            } catch is CancellationError {
                return
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            self?.state = outcome
        }
    }

    private nonisolated static func engine(kind: CaptionEngineKind, endpoint: String, model: String) throws -> any CaptionEngine {
        switch kind {
        case .localEndpoint:
            return LocalEndpointCaptionEngine(endpoint: endpoint, model: model)
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) { return OnDeviceCaptionEngine() }
            #endif
            throw CaptionError.onDeviceUnsupported
        }
    }
}

// MARK: - Views

/// The "Describe file" panel for one file. Shows a disabled button and a hint
/// while the feature is off; the disclaimer label is always visible.
struct CaptionPanel: View {
    let fileURL: URL

    @AppStorage(CaptionSettings.Keys.enabled, store: CaptionSettings.store)
    private var enabled: Bool = CaptionSettings.Defaults.enabled
    @StateObject private var model = CaptionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Describe File") { model.describe(fileURL: fileURL) }
                    .disabled(!enabled || model.state == .running)
                if model.state == .running {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            switch model.state {
            case .idle, .running:
                if !enabled {
                    Text("Turn on \u{201C}Describe file\u{201D} in Settings to write a one-line technical description of this file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .finished(let caption):
                Text(caption.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if caption.usedFallback {
                    Text("The model's answer was withheld; showing a summary of the file header instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("Generated on-device. Not a medical interpretation.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: fileURL) { model.reset() }
        .onDisappear { model.reset() }
    }
}

/// Settings controls for the feature, for the Settings window to embed in a
/// `Form` section. Every control except the master toggle is disabled while
/// the feature is off.
struct CaptionSettingsSection: View {
    @AppStorage(CaptionSettings.Keys.enabled, store: CaptionSettings.store)
    private var enabled: Bool = CaptionSettings.Defaults.enabled
    @AppStorage(CaptionSettings.Keys.engine, store: CaptionSettings.store)
    private var engine: String = CaptionSettings.Defaults.engine
    @AppStorage(CaptionSettings.Keys.endpointURL, store: CaptionSettings.store)
    private var endpointURL: String = CaptionSettings.Defaults.endpointURL
    @AppStorage(CaptionSettings.Keys.endpointModel, store: CaptionSettings.store)
    private var endpointModel: String = CaptionSettings.Defaults.endpointModel
    @AppStorage(CaptionSettings.Keys.includeSliceImage, store: CaptionSettings.store)
    private var includeSliceImage: Bool = CaptionSettings.Defaults.includeSliceImage

    private var endpointProblem: String? {
        guard case .failure(let rejection) = LocalEndpointPolicy.validate(endpointURL) else { return nil }
        return CaptionError.endpointRejected(rejection).errorDescription
    }

    var body: some View {
        Toggle("Describe file (experimental)", isOn: $enabled)
            .disabled(CaptionSettings.enabledIsManaged)
        Text("Writes a one-sentence technical description (likely modality, dimensions, resolution, coverage) using a model on this Mac. Only header facts are used \u{2014} never the file name or free-text fields. Not a medical interpretation.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Group {
            Picker("Model", selection: $engine) {
                ForEach(CaptionEngineKind.allCases) { kind in
                    Text(kind.title).tag(kind.rawValue)
                }
            }
            if engine == CaptionEngineKind.localEndpoint.rawValue {
                TextField("Server URL", text: $endpointURL, prompt: Text(LocalEndpointPolicy.defaultEndpoint))
                if let endpointProblem {
                    Text(endpointProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField("Model name (optional)", text: $endpointModel)
            }
            Toggle("Include centre slice image", isOn: $includeSliceImage)
            Text(sliceFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!enabled)
    }

    private var sliceFootnote: String {
        if engine == CaptionEngineKind.localEndpoint.rawValue {
            return String(localized: "Sends one downsampled axial slice to the local server. Requires a multimodal model (e.g. loaded with --mmproj).")
        }
        #if MIQ_FM_IMAGE_ATTACHMENTS
        if #available(macOS 27, *) {
            return String(localized: "Gives the on-device model one downsampled axial slice.")
        }
        #endif
        return String(localized: "The on-device model on this macOS version uses header facts only.")
    }
}
