import AppKit
import Foundation
import Metal
import SceneKit

/// Renders a model from several angles to PNGs, offscreen.
///
/// Exists because inspecting a scan means *looking* at it, and the alternatives do
/// not work here: `qlmanage` stalls on large USDZ files, and `SCNView.snapshot()`
/// wants a window. `SCNRenderer` on a Metal device needs neither.
///
/// Build:
///   swiftc -O -parse-as-library Tools/RenderViews.swift -o /tmp/renderviews
/// Run:
///   /tmp/renderviews <model.usdz> <output-prefix> [size]
@main
struct RenderViews {

    /// Azimuth/elevation pairs in degrees, plus a label for the file name.
    private static let viewpoints: [(name: String, azimuth: Float, elevation: Float)] = [
        ("ust", 0, 75),
        ("acili", 35, 35),
        ("yan", 90, 15),
        ("karsi", 200, 20),
    ]

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            FileHandle.standardError.write(Data("Kullanım: renderviews <model> <çıktı-öneki> [boyut]\n".utf8))
            exit(2)
        }

        let modelURL = URL(fileURLWithPath: arguments[1])
        let prefix = arguments[2]
        let size = arguments.count > 3 ? (Int(arguments[3]) ?? 1000) : 1000

        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write(Data("Metal cihazı yok.\n".utf8))
            exit(1)
        }

        let scene: SCNScene
        do {
            scene = try SCNScene(url: modelURL, options: [.checkConsistency: false])
        } catch {
            FileHandle.standardError.write(Data("Model açılamadı: \(error)\n".utf8))
            exit(1)
        }

        // Ambient only, and bright. A directional light would sculpt the geometry
        // with its own shadows, which is exactly what must not be confused with the
        // model's real surface detail.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 1000
        scene.rootNode.addChildNode(ambient)

        let (center, radius) = bounds(of: scene.rootNode)
        print("Merkez: \(center)  yarıçap: \(String(format: "%.2f", radius)) m")

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = Double(radius * 20)
        scene.rootNode.addChildNode(camera)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true

        for viewpoint in viewpoints {
            let azimuth = viewpoint.azimuth * .pi / 180
            let elevation = viewpoint.elevation * .pi / 180
            let distance = radius * 2.4

            let offset = SIMD3<Float>(
                distance * cos(elevation) * sin(azimuth),
                distance * sin(elevation),
                distance * cos(elevation) * cos(azimuth)
            )
            camera.simdPosition = center + offset
            camera.simdLook(at: center)

            renderer.pointOfView = camera
            let image = renderer.snapshot(
                atTime: 0,
                with: CGSize(width: size, height: size),
                antialiasingMode: .multisampling4X
            )

            let url = URL(fileURLWithPath: "\(prefix)-\(viewpoint.name).png")
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("PNG üretilemedi: \(viewpoint.name)\n".utf8))
                continue
            }
            try? png.write(to: url)
            print("Yazıldı: \(url.lastPathComponent)")
        }
    }

    /// Centre and bounding radius, walked manually because a bare
    /// `boundingSphere` on the root node ignores child transforms.
    private static func bounds(of node: SCNNode) -> (center: SIMD3<Float>, radius: Float) {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false

        func walk(_ node: SCNNode, transform: simd_float4x4) {
            let combined = transform * simd_float4x4(node.transform)
            if node.geometry != nil {
                let (localMin, localMax) = (node.boundingBox.min, node.boundingBox.max)
                for x in [localMin.x, localMax.x] {
                    for y in [localMin.y, localMax.y] {
                        for z in [localMin.z, localMax.z] {
                            let point = combined * SIMD4<Float>(Float(x), Float(y), Float(z), 1)
                            let position = SIMD3<Float>(point.x, point.y, point.z)
                            minimum = simd_min(minimum, position)
                            maximum = simd_max(maximum, position)
                            found = true
                        }
                    }
                }
            }
            for child in node.childNodes { walk(child, transform: combined) }
        }

        walk(node, transform: matrix_identity_float4x4)
        guard found else { return (.zero, 1) }
        return ((minimum + maximum) / 2, simd_length(maximum - minimum) / 2)
    }
}
