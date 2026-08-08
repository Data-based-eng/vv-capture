import ARKit
import SceneKit
import SwiftUI
import simd

/// Full-screen capture flow for the TrueDepth engine.
struct TrueDepthFlowView: View {
    @Environment(ScanStorage.self) private var storage
    @Environment(\.dismiss) private var dismiss

    @State private var engine: TrueDepthEngine?
    @State private var finishedRecord: ScanRecord?
    @State private var startupError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine {
                content(for: engine)
            } else if let startupError {
                DepthFailureView(message: startupError) { dismiss() }
            } else {
                ProgressView("Hazırlanıyor…").tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .task { startIfNeeded() }
        .onDisappear {
            if finishedRecord == nil { engine?.cancel() }
        }
    }

    @ViewBuilder
    private func content(for engine: TrueDepthEngine) -> some View {
        switch engine.phase {
        case .idle, .preparing, .readyToDetect, .framing, .capturing:
            captureStage(engine: engine)

        case .reconstructing(let progress):
            VStack(spacing: 16) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
                Text(progress.stage?.displayName ?? String(localized: "Nokta bulutu yazılıyor"))
                    .font(.headline)
            }
            .padding(32)

        case .done(let record):
            DepthResultView(record: record) { dismiss() }
                .task { finishedRecord = record }

        case .failed(let message):
            DepthFailureView(message: message) { dismiss() }

        case .cancelled:
            Color.clear.task { dismiss() }
        }
    }

    private func captureStage(engine: TrueDepthEngine) -> some View {
        ZStack {
            if let session = engine.session {
                DepthSceneView(
                    session: session,
                    points: engine.snapshot.renderPoints,
                    aimPoint: engine.snapshot.aimPoint,
                    regionCenter: engine.snapshot.regionCenter,
                    regionHalfExtent: engine.snapshot.regionHalfExtent
                )
                .ignoresSafeArea()

                // Fixed screen-centre reticle. The red aim marker is the centre
                // pixel's surface point reprojected through the same camera, so a
                // correct unprojection puts it inside this reticle. Comparing the two
                // turns "does it look right" into a yes/no.
                CentreReticle()
            } else {
                ProgressView("Sensör başlatılıyor…").tint(.white)
            }

            DepthCaptureOverlay(engine: engine) {
                engine.cancel()
                dismiss()
            }
        }
    }

    private func startIfNeeded() {
        guard engine == nil else { return }
        let engine = TrueDepthEngine(storage: storage)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            startupError = error.localizedDescription
        }
    }
}

// MARK: - Live scene

/// Front camera feed with the accumulating cloud drawn on top.
///
/// SceneKit shares ARKit's camera, so points placed at their world coordinates
/// land exactly over the real surfaces they came from. That overlay *is* the
/// coverage feedback — without it there is no way to tell which side of the
/// object still has holes.
private struct DepthSceneView: UIViewRepresentable {
    let session: ARSession
    let points: [SIMD3<Float>]
    /// World position unprojected from the depth map's centre pixel.
    let aimPoint: SIMD3<Float>?
    let regionCenter: SIMD3<Float>?
    let regionHalfExtent: Float

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.scene.rootNode.addChildNode(context.coordinator.cloudNode)
        view.scene.rootNode.addChildNode(context.coordinator.aimNode)
        view.scene.rootNode.addChildNode(context.coordinator.regionNode)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        context.coordinator.update(points: points)
        context.coordinator.update(aimPoint: aimPoint)
        context.coordinator.update(regionCenter: regionCenter, halfExtent: regionHalfExtent)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let cloudNode = SCNNode()

        /// A single marker at the unprojected centre pixel.
        ///
        /// This is the decisive correctness test, and far easier to read than a
        /// cloud: aim at the middle of the object and the red dot must sit on the
        /// middle of the object. If it lands beside it, the unprojection is wrong —
        /// no interpretation of a smeared cloud needed.
        let aimNode: SCNNode = {
            let sphere = SCNSphere(radius: 0.006)
            sphere.firstMaterial?.lightingModel = .constant
            sphere.firstMaterial?.diffuse.contents = UIColor.systemRed
            let node = SCNNode(geometry: sphere)
            node.isHidden = true
            return node
        }()

        /// Wireframe box for the locked region.
        ///
        /// Doubles as the world-stability check: it is anchored in world space, so if
        /// pose and unprojection agree it stays glued to the object while you walk
        /// around. If it slides off, the problem is upstream of the point cloud.
        let regionNode: SCNNode = {
            let node = SCNNode()
            node.isHidden = true
            return node
        }()

        private var renderedCount = -1
        private var renderedRegionExtent: Float = -1

        func update(regionCenter: SIMD3<Float>?, halfExtent: Float) {
            guard let regionCenter, halfExtent > 0 else {
                regionNode.isHidden = true
                return
            }
            regionNode.isHidden = false
            regionNode.simdPosition = regionCenter

            guard halfExtent != renderedRegionExtent else { return }
            renderedRegionExtent = halfExtent

            let side = CGFloat(halfExtent * 2)
            let box = SCNBox(width: side, height: side, length: side, chamferRadius: 0)
            box.firstMaterial?.lightingModel = .constant
            box.firstMaterial?.diffuse.contents = UIColor.systemYellow
            box.firstMaterial?.fillMode = .lines
            box.firstMaterial?.isDoubleSided = true
            regionNode.geometry = box
        }

        func update(aimPoint: SIMD3<Float>?) {
            guard let aimPoint else {
                aimNode.isHidden = true
                return
            }
            aimNode.isHidden = false
            aimNode.simdPosition = aimPoint
        }

        func update(points: [SIMD3<Float>]) {
            // Snapshots arrive on a timer; rebuilding identical geometry would
            // churn buffers for nothing.
            guard points.count != renderedCount else { return }
            renderedCount = points.count

            guard !points.isEmpty else {
                cloudNode.geometry = nil
                return
            }

            let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
            let source = SCNGeometrySource(vertices: vertices)
            let indices = (0..<UInt32(points.count)).map { $0 }
            let element = SCNGeometryElement(indices: indices, primitiveType: .point)
            element.pointSize = 5
            element.minimumPointScreenSpaceRadius = 2
            element.maximumPointScreenSpaceRadius = 6

            let geometry = SCNGeometry(sources: [source], elements: [element])
            // Constant lighting: these are measurements, not a lit surface, and
            // shading them makes coverage harder to read.
            geometry.firstMaterial?.lightingModel = .constant
            geometry.firstMaterial?.diffuse.contents = UIColor.systemGreen
            geometry.firstMaterial?.isDoubleSided = true

            cloudNode.geometry = geometry
        }
    }
}

// MARK: - Overlay

private struct DepthCaptureOverlay: View {
    let engine: TrueDepthEngine
    let onCancel: () -> Void

    @State private var isFinishing = false
    @State private var isConfirmingCancel = false
    @State private var finishError: String?

    private var snapshot: DepthFrameReceiver.Snapshot { engine.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            if let advice = engine.distanceAdvice {
                // Distance is the cheapest quality lever, so it gets a permanent
                // readout rather than an occasional hint.
                Label(advice.text, systemImage: advice.isGood ? "checkmark.circle.fill" : "arrow.right.and.line.vertical.and.arrow.left")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background((advice.isGood ? Color.green : Color.blue).opacity(0.85), in: Capsule())
                    .padding(.bottom, 8)
            }
            if let warning = engine.trackingWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .padding(.bottom, 12)
            }
            actionBar
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .confirmationDialog("Taramayı iptal et?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button("İptal Et ve Çık", role: .destructive, action: onCancel)
            Button("Taramaya Dön", role: .cancel) {}
        } message: {
            Text("\(snapshot.pointCount) nokta silinecek.")
        }
        .alert(
            "Kaydedilemedi",
            isPresented: Binding(get: { finishError != nil }, set: { if !$0 { finishError = nil } })
        ) {
            Button("Tamam") { finishError = nil }
        } message: {
            Text(finishError ?? "")
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                isConfirmingCancel = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .tint(.white)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(snapshot.pointCount) nokta")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                if let dimensions = snapshot.dimensions {
                    // Live physical size doubles as the metric-scale check: hold a
                    // ruler next to the object and these numbers should match.
                    Text(Self.format(dimensions))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                // Residual depth-to-pose error. Non-zero here means frames are
                // being placed using an extrapolated pose, which is the smearing
                // we are hunting — so it is on screen rather than buried in a log.
                Text("gecikme \(snapshot.poseLagMilliseconds, format: .number.precision(.fractionLength(1))) ms · atılan \(snapshot.framesDropped)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(snapshot.poseLagMilliseconds > 5 ? .orange : .white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.4), in: Capsule())
        }
        .padding(.top, 4)
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            Label("Objeyi 20–100 cm mesafede tutup yavaşça tarayın", systemImage: "wave.3.right")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                if snapshot.isRegionLocked {
                    Button("Bölgeyi Aç") { engine.clearRegion() }
                        .buttonStyle(DepthSecondaryButton())
                } else {
                    Button("Objeyi Kilitle") { engine.lockRegion() }
                        .buttonStyle(DepthSecondaryButton())
                        .disabled(snapshot.aimPoint == nil)
                }

                Picker("Boyut", selection: Binding(
                    get: { engine.regionHalfExtent },
                    set: { engine.regionHalfExtent = $0 }
                )) {
                    Text("15 cm").tag(Float(0.075))
                    Text("30 cm").tag(Float(0.15))
                    Text("60 cm").tag(Float(0.30))
                }
                .pickerStyle(.segmented)
                .disabled(snapshot.isRegionLocked)
            }

            Text(snapshot.isRegionLocked
                 ? "Sadece kilitli bölge birikiyor — masa ve arka plan dışarıda."
                 : "Objeyi kadrajın ortasına alıp kilitleyin: masa ve arka plan elenir, ölçüler objenin olur.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)

            Toggle("Yatay aynala", isOn: Binding(
                get: { engine.processorOptions.mirrorHorizontally },
                set: { engine.processorOptions.mirrorHorizontally = $0 }
            ))
            .font(.footnote)
            .tint(.green)

            Text("Bulut objenin aynası gibi çıkıyorsa bunu açın. Değiştirmek taramayı sıfırlar.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)

            Button {
                finish()
            } label: {
                if isFinishing {
                    ProgressView().tint(.black)
                } else {
                    Text("Bitir ve Kaydet")
                }
            }
            .buttonStyle(DepthPrimaryButton())
            .disabled(isFinishing || snapshot.pointCount == 0)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 22))
        // Front-camera scanning means the screen faces the object, so the user is
        // working blind. A tick every few thousand points is the only signal that
        // data is still arriving — and its absence says something is wrong.
        .sensoryFeedback(.increase, trigger: snapshot.pointCount / 3000)
    }

    private func finish() {
        isFinishing = true
        Task {
            do {
                _ = try await engine.finish()
            } catch {
                finishError = error.localizedDescription
            }
            isFinishing = false
        }
    }

    private static func format(_ dimensions: SIMD3<Float>) -> String {
        let millimetres = dimensions * 1000
        return "\(Int(millimetres.x)) × \(Int(millimetres.y)) × \(Int(millimetres.z)) mm"
    }
}

// MARK: - Result & failure

private struct DepthResultView: View {
    let record: ScanRecord
    let onDone: () -> Void

    @Environment(ScanStorage.self) private var storage

    var body: some View {
        VStack(spacing: 18) {
            // Shown right here rather than only in the library: after a blind
            // scan this is the first chance to see whether it worked at all.
            PointCloudPreviewView(url: storage.modelURL(for: record))
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 6) {
                Text("Nokta bulutu kaydedildi")
                    .font(.headline)
                if let count = record.pointCount {
                    Text("\(count) nokta")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let dimensions = record.dimensionsMillimetres, dimensions.count == 3 {
                    Text("\(dimensions[0]) × \(dimensions[1]) × \(dimensions[2]) mm")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text("Kütüphaneden PLY olarak paylaşabilirsiniz. Mesh'e çevirme henüz eklenmedi.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)

            Button("Bitti", action: onDone)
                .buttonStyle(DepthPrimaryButton())
                .padding(.horizontal, 40)
        }
        .padding(28)
        .sensoryFeedback(.success, trigger: record.id)
    }
}

private struct DepthFailureView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .font(.subheadline)
            Button("Kapat", action: onDismiss)
                .buttonStyle(DepthPrimaryButton())
                .padding(.horizontal, 40)
        }
        .padding(32)
    }
}

private struct DepthPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

private struct DepthSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(.white.opacity(configuration.isPressed ? 0.28 : 0.16), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
    }
}

/// Fixed crosshair at the exact centre of the screen.
private struct CentreReticle: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: 26, height: 26)
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 2, height: 2)
        }
        .allowsHitTesting(false)
    }
}
