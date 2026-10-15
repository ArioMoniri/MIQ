import Foundation
import MIQCore

// Hand-rolled argument parsing for the `miq` tool. Deliberately no
// swift-argument-parser: MIQ ships with zero third-party dependencies, and the
// surface here is three subcommands with a handful of flags. Everything in this
// file is pure (no I/O) so the grammar is unit-tested directly.

/// Intensity window requested on the command line.
enum WindowSpec: Equatable, Sendable {
    /// The preview's behaviour: the shared percentile window of the volume's
    /// three center slices (`MIQVolume.fixedCenterWindow`), so a rendered
    /// off-center slice matches what scrolling to it in Quick Look shows.
    case auto
    /// Explicit raw-intensity bounds (after `scl_slope`/`scl_inter` scaling).
    case fixed(low: Float, high: Float)
}

/// Options shared by `render` and `mosaic`.
struct RenderSettings: Equatable, Sendable {
    var volume: Int = 0
    var window: WindowSpec = .auto
    var orientation: ViewOrientation = .stored
    var segmentation: SegmentationColoring = .auto
    /// Long-side pixel cap per slice — the preview uses 512.
    var maxSize: Int = 512
    /// CT window preset (`--preset`), `nil` when not given. `.auto` picks
    /// `SliceRenderer.ctAutoPreset` when the volume looks like CT
    /// (`WindowPreset.looksLikeCT`) and the percentile window otherwise.
    /// Mutually exclusive with an explicit `--window lo,hi`.
    var preset: WindowPreset?
    /// Direction-encoded colour for 3-vector fields (`DiffusionColor`): `nil` =
    /// automatic (on when `DiffusionColor.vectorComponents` recognises the file and
    /// no explicit `--window`/`--preset` asks for scalar display), `true` = `--dec`
    /// (error if the file is not a vector field), `false` = `--no-dec`.
    var dec: Bool?
}

struct InfoCommand: Equatable, Sendable {
    var path: String
    var json: Bool = false
    /// Also print free-text rows that may carry PHI (`MetadataField.mayContainPHI`:
    /// description, provenance). Off by default, like the preview panel.
    var includePHI: Bool = false
}

struct RenderCommand: Equatable, Sendable {
    var path: String
    var output: String
    var plane: SlicePlane = .axial
    /// `nil` = the center slice along the plane's slice axis.
    var slice: Int?
    var settings = RenderSettings()
}

struct MosaicCommand: Equatable, Sendable {
    var path: String
    var output: String
    /// Smaller default tiles than `render`: the 2×2 canvas is ~2× the tile size.
    var settings = RenderSettings(maxSize: 256)
}

enum CLICommand: Equatable, Sendable {
    /// `topic` is the subcommand whose help was requested, or `nil` for the overview.
    case help(topic: String?)
    case info(InfoCommand)
    case render(RenderCommand)
    case mosaic(MosaicCommand)
}

/// A command-line mistake; printed with the relevant usage text, exit status 2.
struct UsageError: Error, Equatable, CustomStringConvertible {
    let message: String
    /// Subcommand whose usage should accompany the message, if known.
    let topic: String?

    init(_ message: String, topic: String? = nil) {
        self.message = message
        self.topic = topic
    }

    var description: String { message }
}

enum ArgumentParser {
    static let subcommands = ["info", "render", "mosaic"]

    /// Parses `arguments` (excluding the executable name, i.e. `CommandLine.arguments.dropFirst()`).
    ///
    /// Accepted spellings: `--flag value`, `--flag=value`, and `-o value` for the
    /// output path. `--` ends option parsing so a file named `-x.nii` still works.
    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else { return .help(topic: nil) }
        let rest = Array(arguments.dropFirst())

        switch first {
        case "-h", "--help", "help":
            if let topic = rest.first, subcommands.contains(topic) { return .help(topic: topic) }
            return .help(topic: nil)
        case "info":
            return try parseInfo(rest)
        case "render":
            return try parseRender(rest)
        case "mosaic":
            return try parseMosaic(rest)
        default:
            throw UsageError("unknown command '\(first)'")
        }
    }

    // MARK: - Subcommands

    private static func parseInfo(_ args: [String]) throws -> CLICommand {
        var tokens = Tokens(args, topic: "info")
        var json = false
        var includePHI = false
        var positionals: [String] = []
        while let token = tokens.next() {
            switch token {
            case .option("help", _), .option("h", _):
                return .help(topic: "info")
            case .option("json", let inline):
                if inline != nil { throw UsageError("--json takes no value", topic: "info") }
                json = true
            case .option("include-phi", let inline):
                if inline != nil { throw UsageError("--include-phi takes no value", topic: "info") }
                includePHI = true
            case .option(let name, _):
                throw UsageError("unknown option '\(Tokens.spelling(name))' for info", topic: "info")
            case .positional(let value):
                positionals.append(value)
            }
        }
        return .info(InfoCommand(path: try singlePath(positionals, topic: "info"), json: json, includePHI: includePHI))
    }

    private static func parseRender(_ args: [String]) throws -> CLICommand {
        var tokens = Tokens(args, topic: "render")
        var plane: SlicePlane = .axial
        var slice: Int?
        var output: String?
        var settings = RenderSettings()
        var positionals: [String] = []
        while let token = tokens.next() {
            switch token {
            case .option("help", _), .option("h", _):
                return .help(topic: "render")
            case .option("plane", let inline):
                let value = try tokens.value(for: "plane", inline: inline)
                guard let parsed = SlicePlane(rawValue: value.lowercased()) else {
                    throw UsageError("--plane must be axial, coronal or sagittal (got '\(value)')", topic: "render")
                }
                plane = parsed
            case .option("slice", let inline):
                slice = try nonNegativeInt(tokens.value(for: "slice", inline: inline), flag: "slice", topic: "render")
            case .option("o", let inline), .option("output", let inline):
                output = try tokens.value(for: "output", inline: inline)
            case .option(let name, let inline):
                guard try applyShared(name: name, inline: inline, tokens: &tokens, settings: &settings) else {
                    throw UsageError("unknown option '\(Tokens.spelling(name))' for render", topic: "render")
                }
            case .positional(let value):
                positionals.append(value)
            }
        }
        let path = try singlePath(positionals, topic: "render")
        try validateShared(settings, topic: "render")
        guard let output else { throw UsageError("render needs an output file: -o out.png", topic: "render") }
        return .render(RenderCommand(path: path, output: output, plane: plane, slice: slice, settings: settings))
    }

    private static func parseMosaic(_ args: [String]) throws -> CLICommand {
        var tokens = Tokens(args, topic: "mosaic")
        var output: String?
        var settings = MosaicCommand(path: "", output: "").settings
        var positionals: [String] = []
        while let token = tokens.next() {
            switch token {
            case .option("help", _), .option("h", _):
                return .help(topic: "mosaic")
            case .option("o", let inline), .option("output", let inline):
                output = try tokens.value(for: "output", inline: inline)
            case .option(let name, let inline):
                guard try applyShared(name: name, inline: inline, tokens: &tokens, settings: &settings) else {
                    throw UsageError("unknown option '\(Tokens.spelling(name))' for mosaic", topic: "mosaic")
                }
            case .positional(let value):
                positionals.append(value)
            }
        }
        let path = try singlePath(positionals, topic: "mosaic")
        try validateShared(settings, topic: "mosaic")
        guard let output else { throw UsageError("mosaic needs an output file: -o out.png", topic: "mosaic") }
        return .mosaic(MosaicCommand(path: path, output: output, settings: settings))
    }

    // MARK: - Shared options

    /// Applies an option common to `render` and `mosaic`. Returns `false` when
    /// `name` is not one of them, so the caller can report it as unknown.
    private static func applyShared(
        name: String,
        inline: String?,
        tokens: inout Tokens,
        settings: inout RenderSettings
    ) throws -> Bool {
        let topic = tokens.topic
        switch name {
        case "volume", "t":
            settings.volume = try nonNegativeInt(tokens.value(for: name, inline: inline), flag: name, topic: topic)
        case "window":
            settings.window = try parseWindow(tokens.value(for: name, inline: inline), topic: topic)
        case "orientation":
            let value = try tokens.value(for: name, inline: inline).lowercased()
            switch value {
            case "stored": settings.orientation = .stored
            case "neurological", "ras": settings.orientation = .neurological
            case "radiological", "las": settings.orientation = .radiological
            default:
                throw UsageError("--orientation must be stored, neurological or radiological (got '\(value)')", topic: topic)
            }
        case "segmentation":
            let value = try tokens.value(for: name, inline: inline).lowercased()
            guard let parsed = SegmentationColoring(rawValue: value) else {
                throw UsageError("--segmentation must be off, auto or random (got '\(value)')", topic: topic)
            }
            settings.segmentation = parsed
        case "preset":
            let value = try tokens.value(for: name, inline: inline)
            guard let parsed = parsePreset(value) else {
                throw UsageError("--preset must be one of \(presetNames.joined(separator: ", ")) (got '\(value)')", topic: topic)
            }
            settings.preset = parsed
        case "dec", "no-dec":
            if inline != nil { throw UsageError("\(Tokens.spelling(name)) takes no value", topic: topic) }
            settings.dec = name == "dec"
        case "max-size":
            let value = try nonNegativeInt(tokens.value(for: name, inline: inline), flag: name, topic: topic)
            guard (16...4096).contains(value) else {
                throw UsageError("--max-size must be between 16 and 4096", topic: topic)
            }
            settings.maxSize = value
        default:
            return false
        }
        return true
    }

    /// Command-line spellings of `WindowPreset` cases, in menu order with `auto` last
    /// (`softTissue` → `soft-tissue`).
    static var presetNames: [String] {
        (WindowPreset.fixedPresets + [.auto]).map(presetName)
    }

    static func presetName(_ preset: WindowPreset) -> String {
        preset == .softTissue ? "soft-tissue" : preset.rawValue
    }

    /// Case-insensitive; `-`/`_` are ignored, so `soft-tissue`, `soft_tissue` and
    /// `softtissue` all name `.softTissue`.
    static func parsePreset(_ value: String) -> WindowPreset? {
        let key = value.lowercased().filter { $0 != "-" && $0 != "_" }
        return WindowPreset.allCases.first { $0.rawValue.lowercased() == key }
    }

    /// Cross-option checks for `render`/`mosaic` once every flag is read.
    private static func validateShared(_ settings: RenderSettings, topic: String) throws {
        if settings.preset != nil, settings.window != .auto {
            throw UsageError("--preset and --window lo,hi are mutually exclusive", topic: topic)
        }
        if settings.dec == true, settings.preset != nil || settings.window != .auto {
            throw UsageError("--dec colours by direction; it cannot be combined with --window or --preset", topic: topic)
        }
    }

    /// `auto`, or `lo,hi` with finite `lo < hi` (negative values allowed, e.g. `-1000,400` for CT).
    static func parseWindow(_ value: String, topic: String? = nil) throws -> WindowSpec {
        if value.lowercased() == "auto" { return .auto }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let low = Float(parts[0].trimmingCharacters(in: .whitespaces)),
              let high = Float(parts[1].trimmingCharacters(in: .whitespaces)),
              low.isFinite, high.isFinite else {
            throw UsageError("--window must be 'auto' or 'lo,hi' (got '\(value)')", topic: topic)
        }
        guard low < high else {
            throw UsageError("--window lower bound must be below the upper bound", topic: topic)
        }
        return .fixed(low: low, high: high)
    }

    private static func nonNegativeInt(_ value: String, flag: String, topic: String?) throws -> Int {
        guard let parsed = Int(value), parsed >= 0 else {
            throw UsageError("\(Tokens.spelling(flag)) expects a non-negative integer (got '\(value)')", topic: topic)
        }
        return parsed
    }

    private static func singlePath(_ positionals: [String], topic: String) throws -> String {
        guard let path = positionals.first else {
            throw UsageError("\(topic) needs an input file or DICOM folder", topic: topic)
        }
        guard positionals.count == 1 else {
            throw UsageError("\(topic) takes exactly one input file (got \(positionals.count))", topic: topic)
        }
        return path
    }
}

/// Splits raw arguments into options and positionals.
private struct Tokens {
    enum Token: Equatable {
        /// Name without dashes; `inline` is the `=value` part of `--name=value`.
        case option(String, inline: String?)
        case positional(String)
    }

    let topic: String
    private var remaining: ArraySlice<String>
    private var optionsEnded = false

    init(_ args: [String], topic: String) {
        self.remaining = args[...]
        self.topic = topic
    }

    static func spelling(_ name: String) -> String {
        name.count == 1 ? "-\(name)" : "--\(name)"
    }

    mutating func next() -> Token? {
        guard let arg = remaining.popFirst() else { return nil }
        if optionsEnded { return .positional(arg) }
        if arg == "--" {
            optionsEnded = true
            return next()
        }
        // A lone "-" is a positional (conventionally stdin/stdout). Option values
        // that start with "-" (`--window -100,200`) never reach this point: they
        // are consumed by `value(for:inline:)` straight after their flag.
        if arg == "-" || !arg.hasPrefix("-") { return .positional(arg) }
        if arg.hasPrefix("--") {
            let body = arg.dropFirst(2)
            if let eq = body.firstIndex(of: "=") {
                return .option(String(body[..<eq]), inline: String(body[body.index(after: eq)...]))
            }
            return .option(String(body), inline: nil)
        }
        // Single-dash short option, e.g. `-o`. `-ofile.png` is not supported.
        return .option(String(arg.dropFirst()), inline: nil)
    }

    /// The option's value: its inline `=value`, else the next raw argument (which
    /// may start with `-`, so negative window bounds need no special quoting).
    mutating func value(for name: String, inline: String?) throws -> String {
        if let inline { return inline }
        guard let value = remaining.popFirst() else {
            throw UsageError("\(Self.spelling(name)) needs a value", topic: topic)
        }
        return value
    }
}

enum Usage {
    /// Format families, derived from `MIQFileKind` so a new parser shows up here
    /// without touching the CLI ("Compressed …" / "… (detached)" variants folded).
    static var formatFamilies: [String] {
        var seen: [String] = []
        for kind in MIQFileKind.allCases {
            var name = kind.displayName
            if name.hasPrefix("Compressed ") { name.removeFirst("Compressed ".count) }
            if name.hasSuffix(" (detached)") { name.removeLast(" (detached)".count) }
            if kind == .nii || kind == .niiGz { name = "NIfTI-1/2" }
            if kind == .mgh || kind == .mgz { name = "MGH/MGZ" }
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    /// Every file suffix `MIQFileKind(url:)` recognises, e.g. ".nii, .nii.gz, …".
    static var suffixList: String {
        MIQFileKind.allCases.flatMap(\.pathSuffixes).joined(separator: ", ")
    }

    /// `text` broken at ", " into lines of at most `width` characters.
    static func wrapped(_ text: String, indent: String, width: Int = 76) -> String {
        var lines: [String] = []
        var line = indent
        for item in text.components(separatedBy: ", ") {
            let piece = item + ","
            if line.count + piece.count + 1 > width, line != indent {
                lines.append(line)
                line = indent
            }
            line += (line == indent ? "" : " ") + piece
        }
        lines.append(line)
        return lines.joined(separator: "\n")
    }

    static var inputHelp: String {
        """
        INPUT:
          A file ending in
        \(wrapped(suffixList, indent: "    "))
          an extensionless DICOM Part-10 file, or a folder of single-frame DICOM
          slices (stacked into one volume by position; the series of the first
          file by name is used when a folder holds several).
        """
    }

    static var overview: String {
        """
        miq — inspect medical volumes (\(formatFamilies.joined(separator: ", "))) from the terminal.

        USAGE:
          miq info   <file|dicom-folder> [--json] [--include-phi]
          miq render <file|dicom-folder> -o out.png [--plane axial|coronal|sagittal] [--slice N] [render options]
          miq mosaic <file|dicom-folder> -o out.png [render options]
          miq help [command]

        \(inputHelp)

        Uses the same parsers and renderer as the MIQ Quick Look extension. Reads files
        locally only; nothing is uploaded or logged. Not a medical device — not for
        diagnostic use.
        """
    }

    static var info: String {
        """
        USAGE: miq info <file|dicom-folder> [--json] [--include-phi]

        Prints the header summary MIQ's preview shows: format, dimensions, voxel
        spacing, datatype, number of volumes, orientation, qform/sform codes and
        intensity scaling. --json emits a machine-readable object instead.

        Free-text header fields that can hold identifying details (NIfTI descrip /
        intent name, MIF command history) are omitted unless --include-phi is given.

        \(inputHelp)
        """
    }

    static var renderOptions: String {
        """
        RENDER OPTIONS:
          --volume N, -t N        Timepoint/volume to render (0-based, default 0)
          --window auto|lo,hi     Intensity window. 'auto' (default) = the preview's
                                  2–98th percentile window over the center slices;
                                  'lo,hi' = fixed bounds in scaled units, e.g. -1000,400
          --preset NAME           CT window in Hounsfield units, NAME one of
                                  \(ArgumentParser.presetNames.joined(separator: "|")):
                                  brain W80/L40, subdural W200/L75, stroke W40/L40,
                                  bone W1800/L400, lung W1500/L-600, soft-tissue W400/L40;
                                  'auto' = \(ArgumentParser.presetName(SliceRenderer.ctAutoPreset)) when the volume looks like CT
                                  (integer HU data with air near -1024, or DICOM
                                  Modality CT), else the percentile window
          --dec / --no-dec        Direction-encoded colour (R=left-right, G=ant-post,
                                  B=sup-inf) for diffusion vector fields such as
                                  dtifit *_V1 (3 volumes) or a 5D 3-vector NIfTI.
                                  Automatic unless --window/--preset is given;
                                  --no-dec shows one component (pick it with --volume)
          --orientation MODE      stored (default) | neurological | radiological
          --segmentation MODE     auto (default) | off | random — label-volume colouring;
                                  an explicit --window or --preset turns it off
          --max-size N            Long-side pixel cap per slice (render 512, mosaic 256)
        """
    }

    static var render: String {
        """
        USAGE: miq render <file|dicom-folder> -o out.png [--plane axial|coronal|sagittal] [--slice N] [render options]

        Renders one slice to an 8-bit PNG (grayscale, or RGB for colour data,
        coloured segmentations and direction-encoded vector fields). Defaults:
        axial plane, center slice. Use -o - to write the PNG to standard output.

        \(renderOptions)
        """
    }

    static var mosaic: String {
        """
        USAGE: miq mosaic <file|dicom-folder> -o out.png [render options]

        Writes the preview's 2×2 layout as one PNG: coronal (top left), sagittal
        (top right), axial (bottom left) center slices; the bottom-right metadata
        quadrant is left blank (run `miq info` for the text).

        \(renderOptions)
        """
    }

    static func text(for topic: String?) -> String {
        switch topic {
        case "info": return info
        case "render": return render
        case "mosaic": return mosaic
        default: return overview
        }
    }
}
