import SceneKit
import SwiftUI
import simd

/// On-device viewer for a saved point cloud.
///
/// Exists because Quick Look renders a points-only file as nothing, and telling
/// someone to AirDrop every scan to a Mac just to see whether it worked is not a
/// workable loop. Reuses the same SceneKit point geometry the live capture
/// overlay builds.
struct PointCloudPreviewView: View {
    let url: URL

    @State private var points: [SIMD3<Float>] = []
    @State private var loadError: String?

    var body: some View {
        ZStack {
            Color.black

            if !points.isEmpty {
                PointCloudSceneView(points: points)
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding()
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !points.isEmpty {
                Text("\(points.count) nokta")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
        .task(id: url) {
            do {
                // Parsing a few hundred thousand points blocks long enough to drop
                // frames on the main actor.
                points = try await Task.detached(priority: .userInitiated) {
                    try PointCloudFile.read(from: url)
                }.value
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

/// SceneKit view with the cloud recentred on the origin so the built-in camera
/// controls orbit around the object instead of around wherever in the room the
/// scan happened to be captured.
private struct PointCloudSceneView: UIViewRepresentable {
    let points: [SIMD3<Float>]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.scene = makeScene()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // Points are fixed for a given file; nothing to refresh.
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        guard !points.isEmpty else { return scene }

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for point in points {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        let center = (minimum + maximum) / 2
        let extent = simd_length(maximum - minimum)

        let vertices = points.map { SCNVector3($0.x - center.x, $0.y - center.y, $0.z - center.z) }
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: (0..<UInt32(points.count)).map { $0 }, primitiveType: .point)
        element.pointSize = 4
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 5

        let geometry = SCNGeometry(sources: [source], elements: [element])
        // Constant lighting: these are measurements, not a lit surface.
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.diffuse.contents = UIColor.systemGreen

        scene.rootNode.addChildNode(SCNNode(geometry: geometry))

        let camera = SCNCamera()
        camera.zNear = 0.001
        camera.zFar = Double(max(extent * 10, 1))
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, max(extent * 1.4, 0.1))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }
}
