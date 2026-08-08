import Foundation
import ModelIO
import SceneKit

/// Prints geometry statistics for a USDZ.
///
/// The polygon count is the number that decides whether the macOS detour is worth
/// it. "Higher detail" is a claim; vertices and triangles are a measurement.
///
/// Build:
///   swiftc -O -parse-as-library Tools/MeshStats.swift -o /tmp/meshstats
/// Run:
///   /tmp/meshstats <model.usdz> [more.usdz …]
@main
struct MeshStats {

    static func main() {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            FileHandle.standardError.write(Data("Kullanım: meshstats <model.usdz> …\n".utf8))
            exit(2)
        }

        // Padded manually: `String(format:)` ignores width flags on `%@`, which is
        // why an earlier version printed a ragged header.
        print(row("DOSYA", "TEPE", "ÜÇGEN", "BOYUT", "ÖLÇÜ (mm)"))

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("\(url.lastPathComponent): bulunamadı")
                continue
            }

            let asset = MDLAsset(url: url)
            var vertices = 0
            var triangles = 0

            for index in 0..<asset.count {
                walk(asset.object(at: index), vertices: &vertices, triangles: &triangles)
            }

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

            // Read the bounding box through SceneKit: USDZ carries the scene's real
            // units, so this is the check that the model is life-size.
            var measurement = "—"
            if let scene = try? SCNScene(url: url, options: nil) {
                let (minimum, maximum) = scene.rootNode.boundingBox
                let size = SCNVector3(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z)
                measurement = String(
                    format: "%.0f × %.0f × %.0f",
                    Double(size.x) * 1000, Double(size.y) * 1000, Double(size.z) * 1000
                )
            }

            print(row(
                url.lastPathComponent,
                "\(vertices)",
                "\(triangles)",
                ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file),
                measurement
            ))
        }
    }

    private static func row(_ name: String, _ vertices: String, _ triangles: String, _ size: String, _ measure: String) -> String {
        name.padding(toLength: 24, withPad: " ", startingAt: 0)
            + vertices.leftPadded(to: 10)
            + triangles.leftPadded(to: 10)
            + size.leftPadded(to: 12)
            + "   " + measure
    }

    private static func walk(_ object: MDLObject, vertices: inout Int, triangles: inout Int) {
        if let mesh = object as? MDLMesh {
            vertices += mesh.vertexCount
            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
                switch submesh.geometryType {
                case .triangles: triangles += submesh.indexCount / 3
                case .quads: triangles += (submesh.indexCount / 4) * 2
                default: break
                }
            }
        }
        for child in object.children.objects {
            walk(child, vertices: &vertices, triangles: &triangles)
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
