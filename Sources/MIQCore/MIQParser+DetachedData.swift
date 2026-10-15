import Foundation

/// Shared plumbing for detached-header formats (NRRD `.nhdr`, MRtrix `.mih`,
/// MetaImage `.mhd`): a text header names one or more payload files that live next
/// to it. Three concerns are centralised here so every format behaves the same:
///
/// 1. **Path safety.** The file name comes from an untrusted header. Only files in
///    the header's own directory or one of its subdirectories are opened; an
///    absolute path outside that tree, a `..` that climbs out of it, or a symlink
///    that leads out of it is rejected. (A preview must never be a way to make the
///    app read arbitrary files the user didn't pick.)
/// 2. **Sandboxed reads.** A Quick Look extension is usually granted access to the
///    previewed file alone, so the sibling payload can be unreadable even though it
///    exists. That failure is reported as a display-ready
///    `MIQError.unsupportedFeature` naming only the file's *last path component*
///    (never a full path), so the preview explains itself instead of showing a
///    generic I/O error. Callers must not log the name publicly (it can carry
///    patient identifiers); use `MIQLogRedaction.fileTag(_:)` for log lines.
/// 3. **Multi-file payloads.** NRRD and MetaImage can split a volume into slabs,
///    either with an explicit `LIST` or a printf-style `slice%03d.raw <min> <max>
///    <step>` pattern. `DetachedFileList` expands both into the ordered names.
extension MIQParser {
    /// Upper bound on the number of payload files one header may reference. Real
    /// multi-file series are at most a few thousand slices; the cap keeps a crafted
    /// `%d 0 2147483647 1` pattern from expanding into billions of names.
    static let maxDetachedDataFiles = 16_384

    /// The ordered payload file names a detached header references.
    struct DetachedFileList: Equatable {
        /// File names as written in the header (relative to the header's folder).
        let names: [String]
        /// Number of fastest axes each file holds (`nil`: one less than the
        /// dimension count, the NRRD/MetaIO default). Only meaningful when
        /// `names.count > 1`.
        let subdim: Int?
    }

    /// Parses a printf-style multi-file spec `<format> <min> <max> <step> [<subdim>]`
    /// (e.g. `slice%03d.raw 1 40 1 2`). Returns `nil` when `value` isn't in that
    /// form, so the caller treats it as a single file name. Throws for a pattern
    /// whose range is empty, whose step is zero or points the wrong way, or that
    /// would expand past `maxDetachedDataFiles`.
    func parseDetachedFilePattern(_ value: String) throws -> DetachedFileList? {
        let tokens = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count == 4 || tokens.count == 5,
              tokens[0].contains("%"),
              let lo = Int(tokens[1]), let hi = Int(tokens[2]), let step = Int(tokens[3]) else {
            return nil
        }
        let subdim = tokens.count == 5 ? Int(tokens[4]) : nil
        if tokens.count == 5, subdim == nil { return nil }
        guard step != 0, (step > 0 && lo <= hi) || (step < 0 && lo >= hi) else {
            throw MIQError.malformedFile("detached data file pattern has an empty or inverted range")
        }
        let (span, overflow) = hi.subtractingReportingOverflow(lo)
        guard !overflow else { throw MIQError.malformedFile("detached data file pattern range overflows") }
        let count = span / step + 1
        guard count <= Self.maxDetachedDataFiles else {
            throw MIQError.unsupportedFeature("detached data file pattern expands to more than \(Self.maxDetachedDataFiles) files")
        }
        var names: [String] = []
        names.reserveCapacity(count)
        var index = lo
        for _ in 0..<count {
            names.append(try formatDetachedFileName(tokens[0], index: index))
            index += step
        }
        return DetachedFileList(names: names, subdim: subdim)
    }

    /// Substitutes `index` into a printf-style name with exactly one integer
    /// conversion (`%d`, `%i`, `%u`, with optional `0` flag and width, e.g.
    /// `%03d`); `%%` is a literal percent. Anything else — `%s`, `%n`, two
    /// conversions — is rejected rather than handed to a C formatter.
    func formatDetachedFileName(_ format: String, index: Int) throws -> String {
        var result = ""
        var conversions = 0
        var chars = Array(format)[...]
        while let c = chars.popFirst() {
            guard c == "%" else { result.append(c); continue }
            if chars.first == "%" { chars.removeFirst(); result.append("%"); continue }
            var zeroPad = false
            if chars.first == "0" { zeroPad = true; chars.removeFirst() }
            var widthDigits = ""
            while let d = chars.first, d.isASCII, d.isNumber { widthDigits.append(d); chars.removeFirst() }
            guard let conversion = chars.popFirst(), "diu".contains(conversion),
                  widthDigits.count <= 2 else {
                throw MIQError.malformedFile("detached data file pattern supports only one %d conversion")
            }
            conversions += 1
            let width = Int(widthDigits) ?? 0
            let digits = String(index.magnitude)
            let sign = index < 0 ? "-" : ""
            let padCount = max(0, width - digits.count - sign.count)
            result += zeroPad
                ? sign + String(repeating: "0", count: padCount) + digits
                : String(repeating: " ", count: padCount) + sign + digits
        }
        guard conversions == 1 else {
            throw MIQError.malformedFile("detached data file pattern supports only one %d conversion")
        }
        return result
    }

    /// Resolves a payload file `name` from a detached header at `headerURL`.
    ///
    /// Relative names resolve against the header's directory. The result must lie
    /// strictly inside that directory tree (same folder or a subfolder) after
    /// `.`/`..` normalisation **and** symlink resolution; otherwise this throws
    /// `MIQError.unsupportedFeature`. Absolute names are accepted only when they
    /// point into that same tree (some writers record the full path of a file next
    /// to the header). `~` is not expanded, and empty names or names containing NUL
    /// are rejected.
    func resolveDetachedDataFile(_ name: String, relativeTo headerURL: URL) throws -> URL {
        let displayName = Self.detachedDisplayName(name)
        guard !name.isEmpty, !name.contains("\0") else {
            throw MIQError.malformedFile("detached data file name is empty or invalid")
        }
        let directory = headerURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let candidate: URL = name.hasPrefix("/")
            ? URL(fileURLWithPath: name)
            : directory.appendingPathComponent(name)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()

        let dirComponents = directory.pathComponents
        let fileComponents = resolved.pathComponents
        guard fileComponents.count > dirComponents.count,
              Array(fileComponents.prefix(dirComponents.count)) == dirComponents,
              !fileComponents.contains("..") else {
            throw MIQError.unsupportedFeature(
                "Detached data file '\(displayName)' is outside the header's folder; only files in the same folder or a subfolder are read"
            )
        }
        return resolved
    }

    /// Reads a resolved payload file: memory-mapped on a local volume, cancelable
    /// chunked reads on a network one (as for the primary file). A missing file is a
    /// `malformedFile`; any other read failure — typically the Quick Look sandbox
    /// denying access to a file the user didn't select — is the display-ready
    /// `unsupportedFeature` described on this extension. `name` is the header's
    /// spelling; only its last path component appears in errors.
    func readDetachedDataFile(_ url: URL, name: String) throws -> Data {
        let displayName = Self.detachedDisplayName(name)
        do {
            return VolumeLocation.isLocal(url)
                ? try Data(contentsOf: url, options: [.mappedIfSafe])
                : try readCancelable(url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw MIQError.malformedFile("Detached data file '\(displayName)' was not found next to the header")
        } catch {
            throw MIQError.unsupportedFeature(
                "Detached data file '\(displayName)' couldn't be read from Quick Look (sandbox). Open the file in MIQ.app or use the attached-header variant"
            )
        }
    }

    /// The last path component of a header-supplied file name — the only part of
    /// it that ever appears in an error message.
    static func detachedDisplayName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return last.isEmpty ? name : last
    }

    /// Number of payload bytes each file of a multi-file list holds: the product of
    /// the `subdim` fastest sizes (default: all but the slowest axis) times the
    /// bytes per element. Throws unless the remaining (slower) sizes multiply to
    /// exactly `fileCount`.
    func detachedBytesPerFile(sizes: [Int], subdim: Int?, fileCount: Int, bytesPerElement: Int) throws -> Int {
        if fileCount == 1 { return sizes.reduce(bytesPerElement, *) }
        let sub = subdim ?? (sizes.count - 1)
        guard sub >= 1, sub <= sizes.count else {
            throw MIQError.malformedFile("detached data file list has an invalid sub-dimension \(sub)")
        }
        let perFile = sizes.prefix(sub).reduce(bytesPerElement, *)
        let files = sizes.dropFirst(sub).reduce(1, *)
        guard files == fileCount else {
            throw MIQError.malformedFile("detached header lists \(fileCount) data files but its sizes need \(files)")
        }
        return perFile
    }
}
