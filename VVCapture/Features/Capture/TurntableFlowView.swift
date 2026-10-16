import AVFoundation
import SwiftUI

/// Capture flow for turntable photogrammetry: device fixed, object rotating.
///
/// Visual system: amber phosphor on warm near-black (`Brand`), film grain,
/// vignette, 2.5D lifted panels, tilt parallax, and spring entrances.
/// Logic is untouched by the visual pass — see the git history for behavior.
struct TurntableFlowView: View {
    @Environment(ScanStorage.self) private var storage

    @State private var engine: TurntableCaptureEngine?
    @State private var finishedRecord: ScanRecord?
    @State private var startupError: String?
    @AppStorage("vv-capture.hasSeenSetupTips") private var hasSeenSetupTips = false

    /// Screen-space rectangle the user places over the object.
    @State private var maskFrame = CGRect(x: 80, y: 240, width: 220, height: 260)

    /// Called when the flow ends (done, cancelled, or failed to start) so the
    /// host can reset to a fresh capture session.
    var onFinished: () -> Void = {}

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()

            if let engine {
                content(for: engine)
            } else if let startupError {
                TurntableMessageView(
                    title: String(localized: "Couldn't open the camera"),
                    message: startupError,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Brand.danger
                ) { onFinished() }
            } else {
                ProgressView("Preparing…").tint(Brand.phosphor)
            }
        }
        .preferredColorScheme(.dark)
        .task { startIfNeeded() }
        .onDisappear {
            if finishedRecord == nil { engine?.cancel() }
        }
    }

    @ViewBuilder
    private func content(for engine: TurntableCaptureEngine) -> some View {
        switch engine.phase {
        case .idle, .preparing:
            ProgressView("Preparing camera…").tint(Brand.phosphor)

        case .capturing:
            if hasSeenSetupTips {
                captureStage(engine: engine)
            } else {
                // The turntable setup has one make-or-break requirement, and showing
                // it after a failed 40-shot session would be too late.
                TurntableSetupGuide(deliversDepth: engine.deliversDepth) {
                    hasSeenSetupTips = true
                } onCancel: {
                    engine.cancel()
                    onFinished()
                }
            }

        case .reconstructing(let progress):
            TurntableReconstructionView(progress: progress)

        case .done(let record):
            TurntableResultView(record: record, warnings: engine.warnings) { onFinished() }
                .task { finishedRecord = record }

        case .failed(let message):
            TurntableMessageView(
                title: String(localized: "Scan failed"),
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: Brand.danger
            ) { onFinished() }

        case .cancelled:
            Color.clear.task { onFinished() }
        }
    }

    private func captureStage(engine: TurntableCaptureEngine) -> some View {
        ZStack {
            if let session = engine.session {
                // The frame is reported back through a binding rather than read from
                // the view: converting layer coordinates to capture coordinates needs
                // the preview layer, which only this wrapper owns.
                CameraPreviewView(session: session, maskFrame: maskFrame) { normalized in
                    engine.objectMaskRect = normalized
                }
                .ignoresSafeArea()
            }

            // Texture sits over the live preview but under the controls, so the
            // panels keep their contrast.
            VignetteOverlay()
            GrainOverlay(opacity: 0.035)

            ObjectMaskRectangle(frame: $maskFrame)

            TurntableOverlay(engine: engine) {
                engine.cancel()
                onFinished()
            }
        }
    }

    private func startIfNeeded() {
        guard engine == nil else { return }
        let engine = TurntableCaptureEngine(storage: storage)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            startupError = error.localizedDescription
        }
    }
}

// MARK: - Setup guide

private struct TurntableSetupGuide: View {
    let deliversDepth: Bool
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            RuneWatermark()
                .frame(width: 320, height: 320)
                .offset(x: 110, y: -180)
            GrainOverlay()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Turntable setup")
                            .font(.title2.bold())
                            .foregroundStyle(Brand.textPrimary)
                        Rectangle()
                            .fill(Brand.phosphor)
                            .frame(width: 44, height: 3)
                            .phosphorGlow(radius: 8, opacity: 0.6)
                    }
                    .staggerIn(delay: 0)

                    // Now that a mask is supplied, the backdrop is no longer the thing
                    // that makes or breaks the capture — so it is demoted and the mask
                    // takes the top slot instead. Overstating a requirement the app has
                    // since solved just trains people to ignore the guide.
                    requirement(
                        String(localized: "Place the amber frame over the object"),
                        detail: String(localized: "Drag to move, pinch with two fingers to resize. Only the inside of the frame is modeled — table, paper, and background are fully excluded. Because the phone is fixed, one frame covers every shot."),
                        systemImage: "viewfinder.rectangular",
                        isCritical: true
                    )
                    .staggerIn(delay: 0.06)

                    requirement(
                        "A plain background still helps",
                        detail: String(localized: "The frame does the heavy lifting, but if its edges sit close to the object it helps to move the background back a little and use one continuous backdrop instead of loose paper."),
                        systemImage: "square.dashed"
                    )
                    .staggerIn(delay: 0.12)

                    requirement(
                        "Keep the phone still",
                        detail: String(localized: "Use a tripod or prop it up. Don't touch the phone during capture."),
                        systemImage: "iphone.gen3"
                    )
                    .staggerIn(delay: 0.18)

                    requirement(
                        String(localized: "Rotate the object in steps"),
                        detail: String(localized: "Turn ~10° per shot and pause briefly. Continuous rotation causes motion blur and breaks matching."),
                        systemImage: "arrow.trianglehead.clockwise"
                    )
                    .staggerIn(delay: 0.24)

                    // Promoted to critical: this is the one thing that makes turntable
                    // capture structurally harder than orbiting, not just different.
                    // Walking around a lit object keeps every surface point's shading
                    // constant between frames. Rotating the object slides the shading
                    // across the surface, so the solver sees a different-looking patch
                    // each time and stops matching it.
                    requirement(
                        String(localized: "Soft light from all sides — or alignment suffers"),
                        detail: String(localized: "As the object turns, the light stays fixed relative to it. Shadows slide across the surface and the solver can't recognize the same point in two frames. Use diffuse light instead of a single lamp; if possible, rotate the lamp with the object."),
                        systemImage: "lightbulb.fill",
                        isCritical: true
                    )
                    .staggerIn(delay: 0.3)

                    requirement(
                        String(localized: "One revolution isn't enough — change the height"),
                        detail: String(localized: "Shots from one height form a single ring with no vertical parallax, so top surfaces come out soft. After one revolution, change the phone's height/angle and shoot another. Flip the object and repeat for the bottom."),
                        systemImage: "arrow.up.and.down",
                        isCritical: true
                    )
                    .staggerIn(delay: 0.36)

                    if !deliversDepth {
                        Label(
                            "This device can't embed depth in photos — the model won't be true to scale.",
                            systemImage: "ruler"
                        )
                        .font(.footnote)
                        .foregroundStyle(Brand.danger)
                        .staggerIn(delay: 0.42)
                    }

                    Button("Got it, Start", action: onContinue)
                        .buttonStyle(BrandPrimaryButton())
                        .padding(.top, 4)
                        .staggerIn(delay: 0.48)

                    Button("Cancel", action: onCancel)
                        .font(.footnote)
                        .foregroundStyle(Brand.textTertiary)
                        .frame(maxWidth: .infinity)
                        .staggerIn(delay: 0.54)
                }
                .padding(24)
            }
        }
    }

    private func requirement(
        _ title: String,
        detail: String,
        systemImage: String,
        isCritical: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(isCritical ? Brand.phosphor : Brand.textSecondary)
                .phosphorGlow(radius: 6, opacity: isCritical ? 0.5 : 0)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCritical ? Brand.phosphorBright : Brand.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview layer

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let maskFrame: CGRect
    let onMaskChange: (CGRect) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // `metadataOutputRectConverted` is the only correct way to go from on-screen
        // coordinates to the capture device's normalised space: it accounts for
        // `videoGravity` cropping and the preview's own orientation, which hand-rolled
        // arithmetic would get wrong.
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let converted = view.previewLayer.metadataOutputRectConverted(fromLayerRect: maskFrame)
        onMaskChange(converted)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Overlay

private struct TurntableOverlay: View {
    let engine: TurntableCaptureEngine
    let onCancel: () -> Void

    @State private var isFinishing = false
    @State private var isConfirmingCancel = false
    @State private var finishError: String?
    @State private var rippleScale: CGFloat = 1
    @State private var rippleOpacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            if let reason = engine.lastRejectionReason, engine.rejectedShots > 0 {
                Label(reason, systemImage: "camera.metering.none")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.phosphor, in: Capsule())
                    .phosphorGlow(radius: 8, opacity: 0.4)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let error = engine.captureError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.danger.opacity(0.92), in: Capsule())
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            actionBar
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: engine.phase)
        .confirmationDialog("Cancel the scan?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button("Discard and Exit", role: .destructive, action: onCancel)
            Button("Back to Scan", role: .cancel) {}
        } message: {
            Text("\(engine.shotCount) photos will be deleted.")
        }
        .alert(
            "Couldn't create the model",
            isPresented: Binding(get: { finishError != nil }, set: { if !$0 { finishError = nil } })
        ) {
            Button("OK") { finishError = nil }
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
                    .frame(width: 36, height: 36)
                    .background(Brand.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Brand.panelEdge, lineWidth: 1)
                    )
            }
            .tint(Brand.textPrimary)
            .accessibilityLabel(String(localized: "Cancel scan"))

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(engine.shotCount) photos")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Brand.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: engine.shotCount)
                HStack(spacing: 5) {
                    if engine.megapixels > 0 {
                        Text("\(engine.megapixels) MP")
                    }
                    if engine.isLocked {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(Brand.phosphor)
                    }
                    if engine.rejectedShots > 0 {
                        Text("· \(engine.rejectedShots) blurry")
                            .foregroundStyle(Brand.phosphorBright)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Brand.textSecondary)
                if !engine.canFinish {
                    Text("at least \(TurntableCaptureEngine.minimumShots)")
                        .font(.caption2)
                        .foregroundStyle(Brand.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Brand.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.panelEdge, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
        }
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            // Prompted at the moment it becomes actionable rather than buried in the
            // setup guide: a single ring of camera positions is the measured cause
            // of soft top and bottom surfaces.
            if engine.shouldChangeElevation {
                Label(
                    "One revolution done — change the phone's height or angle and shoot another",
                    systemImage: "arrow.up.and.down.circle.fill"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.phosphorBright)
                .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 8) {
                    if engine.isAutoCapturing {
                        PulsingDot()
                    }
                    Text(engine.isAutoCapturing
                         ? "Auto-capture is on — keep rotating the object slowly"
                         : "Rotate the object ~10° and shoot")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: 12) {
                Button {
                    engine.lockCameraSettings()
                } label: {
                    switch engine.lockState {
                    case .unlocked: Text("Lock Focus")
                    // Locking waits for focus and exposure to converge, which takes a
                    // moment — without this the button looked like it did nothing.
                    case .locking: Label("Locking…", systemImage: "circle.dotted")
                    case .locked: Label("Focus Locked", systemImage: "lock.fill")
                    case .failed: Label("Couldn't Lock", systemImage: "lock.slash")
                    }
                }
                .buttonStyle(BrandSecondaryButton())
                .disabled(engine.lockState == .locking || engine.lockState == .locked)

                Button(engine.isAutoCapturing ? "Stop Auto" : "Auto Capture") {
                    engine.toggleAutoCapture()
                }
                .buttonStyle(BrandSecondaryButton())

                Button {
                    engine.captureNow()
                    fireRipple()
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.title3)
                        .frame(width: 56, height: 48)
                        .accessibilityLabel(String(localized: "Take photo"))
                }
                .buttonStyle(BrandSecondaryButton())
                .disabled(engine.isAutoCapturing)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Brand.phosphor, lineWidth: 2)
                        .scaleEffect(rippleScale)
                        .opacity(rippleOpacity)
                }
            }

            Button {
                finish()
            } label: {
                if isFinishing {
                    ProgressView().tint(.black)
                } else {
                    Text("Finish and Build Model")
                }
            }
            .buttonStyle(BrandPrimaryButton())
            .disabled(isFinishing || !engine.canFinish)

            if !engine.canFinish {
                Text("The solver needs at least \(TurntableCaptureEngine.minimumShots) photos to close the loop.")
                    .font(.caption2)
                    .foregroundStyle(Brand.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .depthPanel(cornerRadius: 18)
        .tiltParallax(magnitude: 5)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        // The device is on a tripod and the user is looking at the object, so a tick
        // per saved shot is the confirmation that matters.
        .sensoryFeedback(.impact(weight: .light), trigger: engine.shotCount)
    }

    private func fireRipple() {
        rippleScale = 0.9
        rippleOpacity = 0.9
        withAnimation(.easeOut(duration: 0.45)) {
            rippleScale = 1.7
            rippleOpacity = 0
        }
    }

    private func finish() {
        isFinishing = true
        Task {
            defer { isFinishing = false }
            do {
                _ = try await engine.finish()
            } catch {
                // A cancel that lands mid-finish resolves through the .cancelled
                // phase; surfacing it as a failure alert would be wrong.
                if case ScanEngineError.cancelled = error { return }
                finishError = error.localizedDescription
            }
        }
    }
}

/// Breathing amber dot marking a live auto-capture.
private struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Brand.phosphor)
            .frame(width: 8, height: 8)
            .phosphorGlow(radius: 8, opacity: 0.8)
            .scaleEffect(pulse ? 1.4 : 1)
            .opacity(pulse ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse.toggle()
                }
            }
    }
}

// MARK: - Reconstruction, result, message

private struct TurntableReconstructionView: View {
    let progress: ReconstructionProgress

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            RuneWatermark()
                .frame(width: 280, height: 280)
            GrainOverlay()

            VStack(spacing: 18) {
                ShimmerProgressBar(fraction: progress.fraction)
                    .frame(maxWidth: 240)

                Text(progress.stage?.displayName ?? String(localized: "Building model"))
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                    // The stage enum isn't Hashable; its raw value is a stable identity.
                    .id(progress.stage?.rawValue ?? -1)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                if let remaining = progress.remainingText {
                    Text("\(remaining) left")
                        .font(.subheadline)
                        .foregroundStyle(Brand.textSecondary)
                }
                Text("Don't background the app.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textTertiary)
            }
            .padding(28)
            .depthPanel()
            .padding(.horizontal, 40)
            .staggerIn(delay: 0.05)
        }
        .animation(.easeInOut(duration: 0.3), value: progress.stage?.rawValue ?? -1)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Progress bar with a travelling sheen — a long solver run should read as
/// working, not stuck.
private struct ShimmerProgressBar: View {
    var fraction: Double
    @State private var sweep: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Brand.phosphor.gradient)
                    .frame(width: width * max(0.03, fraction))
                    .overlay {
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.55), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 64)
                        .offset(x: sweep * width)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .phosphorGlow(radius: 10, opacity: 0.45)
            }
        }
        .frame(height: 10)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                sweep = 1.4
            }
        }
    }
}

private struct TurntableResultView: View {
    let record: ScanRecord
    /// Surfaced next to the result rather than only logged: if masking was skipped
    /// the model will contain background, and that is worth knowing while looking
    /// at it.
    let warnings: [String]
    let onDone: () -> Void

    @Environment(ScanStorage.self) private var storage

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            GrainOverlay()

            // Scrollable because the pose diagnosis can run to three paragraphs, and a
            // clipped explanation is worse than no explanation.
            ScrollView {
                content
            }
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            ModelPreviewView(url: storage.modelURL(for: record))
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Brand.panelEdge, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 10)
                .staggerIn(delay: 0)

            VStack(spacing: 4) {
                Label("Scan ready", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Brand.ok)
                if let count = record.imageCount {
                    Text("\(count) photos processed")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
                // The three numbers that explain the mesh: how many frames actually
                // got aligned, and how the cameras were spread around the object.
                if let summary = record.summary {
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Brand.textTertiary)
                }
                if !record.isMetricallyScaled {
                    Text("Unscaled — no depth data")
                        .font(.caption)
                        .foregroundStyle(Brand.phosphorBright)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .depthPanel()
            .staggerIn(delay: 0.08)

            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(Brand.phosphorBright)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .staggerIn(delay: 0.14)
            }

            Button("Done", action: onDone)
                .buttonStyle(BrandPrimaryButton())
                .padding(.horizontal, 40)
                .staggerIn(delay: 0.2)
        }
        .padding()
        .sensoryFeedback(.success, trigger: record.id)
    }
}

private struct TurntableMessageView: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            GrainOverlay()

            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                Button("Close", action: onDismiss)
                    .buttonStyle(BrandPrimaryButton())
                    .padding(.horizontal, 40)
            }
            .padding(32)
            .depthPanel()
            .padding(.horizontal, 24)
            .staggerIn(delay: 0.05)
        }
    }
}

/// Draggable, pinchable rectangle marking the object.
private struct ObjectMaskRectangle: View {
    @Binding var frame: CGRect

    @State private var dragOffset = CGSize.zero
    @State private var scale: CGFloat = 1

    private var displayed: CGRect {
        let width = frame.width * scale
        let height = frame.height * scale
        return CGRect(
            x: frame.midX - width / 2 + dragOffset.width,
            y: frame.midY - height / 2 + dragOffset.height,
            width: width,
            height: height
        )
    }

    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .stroke(Brand.phosphor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                .background(Brand.phosphor.opacity(0.06))
                .phosphorGlow(radius: 6, opacity: 0.25)
                .frame(width: displayed.width, height: displayed.height)
                .position(x: displayed.midX, y: displayed.midY)
                .overlay(alignment: .topLeading) {
                    Text("object")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Brand.phosphor, in: Capsule())
                        .position(x: displayed.minX + 22, y: displayed.minY - 10)
                }
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { _ in
                            frame = displayed
                            dragOffset = .zero
                            scale = 1
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { scale = $0.magnification }
                        .onEnded { _ in
                            frame = displayed
                            dragOffset = .zero
                            scale = 1
                        }
                )
        }
        .allowsHitTesting(true)
    }
}
