import Foundation
import MIQCore

/// Entry point of the `miq` command-line tool. All logic lives in
/// `ArgumentParser` / `SliceRenderer` / `InfoReport`; this type only does I/O
/// and maps outcomes to exit statuses (0 success, 1 runtime error, 2 usage error).
@main
enum MIQTool {
    static func main() {
        exit(run(Array(CommandLine.arguments.dropFirst())))
    }

    static func run(_ arguments: [String]) -> Int32 {
        let command: CLICommand
        do {
            command = try ArgumentParser.parse(arguments)
        } catch let error as UsageError {
            writeError("miq: \(error.message)\n\n\(Usage.text(for: error.topic))\n")
            return 2
        } catch {
            writeError("miq: \(error)\n")
            return 2
        }

        do {
            switch command {
            case .help(let topic):
                writeOut(Data((Usage.text(for: topic) + "\n").utf8))
            case .info(let info):
                let (url, image, kind) = try VolumeLoader.load(path: info.path, needsAllVolumes: false)
                let report = InfoReport(url: url, image: image, kind: kind, includePHI: info.includePHI)
                writeOut(info.json ? try report.jsonData() : Data(report.text().utf8))
            case .render(let render):
                try emit(SliceRenderer.render(render), to: render.output)
            case .mosaic(let mosaic):
                try emit(SliceRenderer.mosaic(mosaic), to: mosaic.output)
            }
            return 0
        } catch let error as CommandError {
            writeError("miq: error: \(error.message)\n")
        } catch {
            writeError("miq: error: \(error.localizedDescription)\n")
        }
        return 1
    }

    /// Writes `data` to `path`, or to standard output for `-`.
    private static func emit(_ data: Data, to path: String) throws {
        if path == "-" {
            writeOut(data)
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw CommandError("cannot write \(path): \(error.localizedDescription)")
        }
    }

    private static func writeOut(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }

    private static func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
