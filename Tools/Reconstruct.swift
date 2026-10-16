import Foundation
import ImageIO
import RealityKit

/// macOS-side reconstruction for image sets captured by the iOS app.
///
/// Exists because of a hard platform split: `PhotogrammetrySession.Request.Detail`
/// declares `medium`, `full` and `raw` only on macOS — the iOS SDK exposes
/// `reduced` alone. Same framework, same photos, far higher polygon count.
///
/// Build:
///   swiftc -O Tools/Reconstruct.swift -o /tmp/reconstruct
/// Run:
///   /tmp/reconstruct <images-dir> <output.usdz> [preview|reduced|medium|full|raw] [--room]
///
/// `--room` turns off object masking. That masking looks for one subject per frame
/// and cuts the rest away, which is right for an object on a table and wrong for a
/// room — there the room *is* the subject.
@main
struct Reconstruct {

    static func main() async {
        let arguments = CommandLine.arguments

        guard arguments.count >= 3 else {
            FileHandle.standardError.write(Data("""
                Usage: reconstruct <image-folder> <output.usdz> [detail] [--room]
                  detail: preview | reduced | medium | full | raw   (default: full)
                  --room: disable object masking (for room scans)
                """.utf8))
            exit(2)
        }

        let inputURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let outputURL = URL(fileURLWithPath: arguments[2])
        let flags = arguments.dropFirst(3).map { $0.lowercased() }
        let isRoom = flags.contains("--room")
        let detailName = flags.first(where: { !$0.hasPrefix("--") }) ?? "full"

        guard let detail = detailLevel(named: detailName) else {
            FileHandle.standardError.write(Data("Bilinmeyen detay seviyesi: \(detailName)\n".utf8))
            exit(2)
        }

        guard PhotogrammetrySession.isSupported else {
            FileHandle.standardError.write(Data("Bu Mac fotogrametriyi desteklemiyor.\n".utf8))
            exit(1)
        }

        let images = (try? FileManager.default.contentsOfDirectory(atPath: inputURL.path))?
            .filter { !$0.hasPrefix(".") } ?? []
        print("Input: \(images.count) files — \(inputURL.path)")
        print("Detail: \(detailName)\(isRoom ? " · room mode (masking off)" : "")")
        reportDepthAvailability(in: inputURL, sample: images.first)

        // Checkpoints let an interrupted run resume instead of restarting, which
        // matters when a full-detail pass takes tens of minutes.
        let checkpointURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("checkpoint", isDirectory: true)
        try? FileManager.default.createDirectory(at: checkpointURL, withIntermediateDirectories: true)

        var configuration = PhotogrammetrySession.Configuration(checkpointDirectory: checkpointURL)
        // Guided capture and turntable capture both write images in orbit order,
        // which spares the solver an all-pairs matching search.
        configuration.sampleOrdering = .sequential
        configuration.featureSensitivity = .high
        configuration.isObjectMaskingEnabled = !isRoom

        try? FileManager.default.removeItem(at: outputURL)

        let session: PhotogrammetrySession
        do {
            session = try PhotogrammetrySession(input: inputURL, configuration: configuration)
            try session.process(requests: [.modelFile(url: outputURL, detail: detail)])
        } catch {
            FileHandle.standardError.write(Data("Could not start session: \(error)\n".utf8))
            exit(1)
        }

        let started = Date()
        var lastReported = -1

        do {
            for try await output in session.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    let percent = Int(fraction * 100)
                    // One line per percent; anything finer just floods the terminal.
                    if percent != lastReported {
                        lastReported = percent
                        let elapsed = Int(Date().timeIntervalSince(started))
                        print("  \(percent)%  (\(elapsed / 60)d \(elapsed % 60)s)")
                    }

                case .requestProgressInfo(_, let info):
                    if let stage = info.processingStage {
                        print("Stage: \(stage)")
                    }

                case .requestComplete(_, let result):
                    if case .modelFile(let url) = result {
                        print("Model written: \(url.path)")
                    }

                case .processingComplete:
                    let elapsed = Int(Date().timeIntervalSince(started))
                    print("Done — \(elapsed / 60) min \(elapsed % 60) s")
                    reportSize(of: outputURL)
                    exit(0)

                case .requestError(_, let error):
                    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
                    exit(1)

                case .processingCancelled:
                    FileHandle.standardError.write(Data("Cancelled.\n".utf8))
                    exit(1)

                case .invalidSample(let id, let reason):
                    print("Invalid sample \(id): \(reason)")

                case .skippedSample(let id):
                    print("Skipped sample \(id)")

                case .automaticDownsampling:
                    // Worth surfacing: it silently caps the detail the run can reach.
                    print("WARNING: ran low on memory, quality was reduced automatically")

                case .stitchingIncomplete:
                    print("WARNING: fusion did not finish — the model may be incomplete")

                case .inputComplete:
                    print("Input read, solving…")

                @unknown default:
                    break
                }
            }
        } catch {
            FileHandle.standardError.write(Data("Stream error: \(error)\n".utf8))
            exit(1)
        }

        exit(0)
    }

    private static func detailLevel(named name: String) -> PhotogrammetrySession.Request.Detail? {
        switch name {
        case "preview": .preview
        case "reduced": .reduced
        case "medium": .medium
        case "full": .full
        case "raw": .raw
        default: nil
        }
    }

    /// Metric scale rides along in the depth auxiliary data. Without it the mesh is
    /// still correct in shape but arbitrary in size, so it is worth stating up front.
    private static func reportDepthAvailability(in directory: URL, sample: String?) {
        guard let sample else { return }
        let url = directory.appendingPathComponent(sample)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let hasDepth = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) != nil
        print(hasDepth
              ? "Depth data: present — the model will be true to scale"
              : "Depth data: MISSING — the model will have no scale")
    }

    private static func reportSize(of url: URL) {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64 else { return }
        print("File size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
    }
}

