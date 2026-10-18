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

    /// The capture overlay's origin in window coordinates. The mask rect above
    /// lives in overlay (safe-area-inset) space; it is shifted by this origin
    /// into window space before `MaskCoordinateSpace` converts it.
    @State private var overlayWindowOrigin = CGPoint.zero

    /// Called when the flow ends (done, cancelled, or failed to start) so the
    /// host can reset to a fresh capture session.
    var onFinished: () -> Void = {}

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            if let engine {
                content(for: engine)
            } else if let startupError {
                TurntableMessageView(
                    title: String(localized: "Couldn't open the camera"),
                    message: startupError,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Brand.signal
                ) { onFinished() }
            } else {
                ProgressView("Preparing…").font(BrandFont.mono(14)).tint(Brand.accent)
            }
        }
        .task { await startIfNeeded() }
        // M29: the screen stays awake for capture, video processing, and
        // reconstruction — driven by phase, not by view appear/disappear, so a
        // phase swap can't leave the timer in the wrong state.
        .onChange(of: engine?.phase.keepsScreenAwake ?? false, initial: true) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .onDisappear {
            // Belt and braces: re-enable even if the phase never got there.
            UIApplication.shared.isIdleTimerDisabled = false
            if finishedRecord == nil { engine?.cancel() }
        }
    }

    @ViewBuilder
    private func content(for engine: TurntableCaptureEngine) -> some View {
        switch engine.phase {
        case .idle, .preparing:
            ProgressView("Preparing camera…").font(BrandFont.mono(14)).tint(Brand.accent)

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

        case .processingVideo(let progress):
            TurntableVideoProcessingView(progress: progress)

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
                tint: Brand.signal
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
                CameraPreviewView(
                    session: session,
                    // The drag rect lives in this overlay's safe-area-inset space;
                    // shift it into window space for the conversion (M26).
                    maskFrame: maskFrame.offsetBy(dx: overlayWindowOrigin.x, dy: overlayWindowOrigin.y)
                ) { normalized in
                    engine.objectMaskRect = normalized
                }
                .ignoresSafeArea()
            }

            // Texture sits over the live preview but under the controls, so the
            // panels keep their contrast.
            ScanlineOverlay()

            ObjectMaskRectangle(frame: $maskFrame)

            TurntableOverlay(engine: engine) {
                engine.cancel()
                onFinished()
            }
        }
        // Measure the overlay's window origin so the mask rect can be shifted
        // out of safe-area-inset space (M26). `.global` matches UIKit window
        // coordinates on this full-screen iPhone app.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: OverlayWindowOriginKey.self,
                    value: proxy.frame(in: .global).origin
                )
            }
        )
        .onPreferenceChange(OverlayWindowOriginKey.self) { overlayWindowOrigin = $0 }
    }

    /// `start()` is `async throws`: it gates on
    /// `CameraPermission.ensureVideoAccess()` (C1) before configuring the
    /// session, so a denial lands here in `startupError` instead of a black
    /// preview. See the `ScanEngine` protocol note in CHANGES.md.
    private func startIfNeeded() async {
        guard engine == nil else { return }
        let engine = TurntableCaptureEngine(storage: storage)
        do {
            try await engine.start()
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
            Brand.bg.ignoresSafeArea()
            RuneWatermark()
                .frame(width: 320, height: 320)
                .offset(x: 110, y: -180)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        BrandHeading(text: "Turntable setup")
                        AccentTopRule()
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
                        String(localized: "A plain background still helps"),
                        detail: String(localized: "The frame does the heavy lifting, but if its edges sit close to the object it helps to move the background back a little and use one continuous backdrop instead of loose paper."),
                        systemImage: "square.dashed"
                    )
                    .staggerIn(delay: 0.12)

                    requirement(
                        String(localized: "Keep the phone still"),
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
                        .font(BrandFont.mono(13))
                        .foregroundStyle(Brand.signal)
                        .staggerIn(delay: 0.42)
                    }

                    Button("Got it, Start", action: onContinue)
                        .buttonStyle(BrandPrimaryButton())
                        .padding(.top, 4)
                        .staggerIn(delay: 0.48)

                    Button("Cancel", action: onCancel)
                        .font(BrandFont.mono(13, weight: .medium))
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.muted)
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
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 26)
                .foregroundStyle(isCritical ? Brand.accent : Brand.muted)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(BrandFont.mono(15, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(isCritical ? Brand.accent : Brand.text)
                Text(detail)
                    .font(BrandFont.mono(13))
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview layer

/// The capture overlay's origin in window coordinates, measured at layout
/// time. The draggable mask rect lives in the overlay's (safe-area-inset)
/// space, but `MaskCoordinateSpace` needs window coordinates — the flow views
/// shift the rect by this origin before converting. Defined once here; both
/// capture flows share it.
struct OverlayWindowOriginKey: PreferenceKey {
    static var defaultValue: CGPoint { .zero }
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

/// Converts the on-screen mask rectangle into the normalized image space the
/// mask pipeline (`MaskedSampleSequence` / `ObjectMaskBuilder`) stamps onto.
///
/// Two stacked bugs lived here (C3 + M26), both confirmed by Apple's docs
/// (see research pack `research/ui-flows/RESEARCH.md`):
///
/// M26 — `metadataOutputRectConverted(fromLayerRect:)` takes coordinates in the
/// *preview layer's* space, but the drag rect lives in the SwiftUI overlay's
/// space, which is inset by the safe area while the preview view ignores it.
/// Feeding overlay coordinates straight in shifted the stamped mask up by the
/// top inset (~59pt on the 15 Pro Max). The call site shifts the rect into
/// window coordinates first (via the overlay's measured window origin, above);
/// here we subtract the preview view's own window origin to land in layer
/// space.
///
/// C3 — that conversion returns a normalized rect on the *unrotated* image:
/// sensor-native landscape, even in a portrait UI. The video buffers are
/// stored rotated 90° with an EXIF orientation flag, so the mask pipeline
/// stamps onto EXIF-upright portrait buffers. We counter-rotate the rect 90°
/// into normalized upright-portrait space (origin top-left) before handing it
/// over — the contract the mask side relies on.
///
/// The transform accounts for the layer's `videoGravity` (here
/// `.resizeAspectFill`) because `metadataOutputRectConverted` does; a rect
/// inside the visible area may legitimately land outside 0…1 after the crop,
/// and is passed through unclamped.
enum MaskCoordinateSpace {
    /// Full pipeline: window-space rect → normalized upright-portrait rect.
    static func normalizedUprightRect(forWindowRect rect: CGRect, in view: UIView) -> CGRect {
        // M26: window coords → layer coords.
        let viewFrameInWindow = view.convert(view.bounds, to: nil)
        let layerRect = rect.offsetBy(
            dx: -viewFrameInWindow.origin.x,
            dy: -viewFrameInWindow.origin.y
        )
        guard view.bounds.width > 0, view.bounds.height > 0,
              let layer = view.layer as? AVCaptureVideoPreviewLayer
        else { return .zero }
        let sensorRect = layer.metadataOutputRectConverted(fromLayerRect: layerRect)
        // C3: sensor-landscape → upright portrait.
        return derotatedToUpright(sensorRect)
    }

    /// Sensor-landscape (x→right along the long axis, y→down) → upright
    /// portrait (origin top-left).
    ///
    /// Portrait buffers are the landscape buffer rotated 90° CW (EXIF
    /// orientation 6), so landscape point (lx, ly) lands at (1 − ly, lx).
    /// A rect (sx, sy, sw, sh) therefore becomes (1 − sy − sh, sx, sh, sw).
    /// Sanity: full frame maps to full frame, and the landscape right edge
    /// maps to the portrait bottom edge.
    static func derotatedToUpright(_ sensor: CGRect) -> CGRect {
        CGRect(
            x: 1 - sensor.minY - sensor.height,
            y: sensor.minX,
            width: sensor.height,
            height: sensor.width
        )
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let maskFrame: CGRect
    let onMaskChange: (CGRect) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ view: PreviewView, context: Context) {
        let converted = MaskCoordinateSpace.normalizedUprightRect(forWindowRect: maskFrame, in: view)
        // Push only on change: updateUIView runs on every render, and the
        // engine re-stamps the mask each time it receives one.
        context.coordinator.push(converted, onChange: onMaskChange)
    }

    /// Change-detection so the mask rect isn't pushed to the engine on every
    /// render — only when the user actually moved or resized it.
    final class Coordinator {
        private var lastSent: CGRect?

        func push(_ rect: CGRect, onChange: (CGRect) -> Void) {
            // Rounded so float jitter can't spam "new" rects.
            let rounded = CGRect(
                x: (rect.minX * 4096).rounded() / 4096,
                y: (rect.minY * 4096).rounded() / 4096,
                width: (rect.width * 4096).rounded() / 4096,
                height: (rect.height * 4096).rounded() / 4096
            )
            guard rounded != lastSent else { return }
            lastSent = rounded
            onChange(rounded)
        }
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
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
            // Coverage readout: the 3D ring shows where in space each image was
            // taken, the notches show which sides are captured. Tied to the
            // engine's shots-per-revolution so the ring always means one turn.
            HStack {
                CoverageCard(
                    indices: engine.capturedShotIndices,
                    notchCount: TurntableCaptureEngine.shotsPerRevolution
                )
                .frame(width: 148)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            Spacer(minLength: 0)
            if let reason = engine.lastRejectionReason, engine.rejectedShots > 0 {
                Label(reason, systemImage: "camera.metering.none")
                    .font(BrandFont.mono(12, weight: .medium))
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.accent)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let error = engine.captureError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(BrandFont.mono(12, weight: .medium))
                    .foregroundStyle(Brand.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.signal.opacity(0.92), in: Rectangle())
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            actionBar
            }
            .padding(.horizontal)
            // M30: the X button sat under the Dynamic Island and Finish under
            // the home indicator on the 15 Pro Max — respect the real insets.
            .padding(.top, geo.safeAreaInsets.top)
            .padding(.bottom, geo.safeAreaInsets.bottom + 8)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: engine.phase)
            .confirmationDialog("Cancel the scan?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
                Button("Discard and Exit", role: .destructive, action: onCancel)
                Button("Back to Scan", role: .cancel) {}
            } message: {
                // A video take has no photos; tell the user what's actually lost.
                if engine.isRecordingVideo || engine.recordedVideoURL != nil {
                    Text("The recorded video will be deleted.")
                } else {
                    Text("\(engine.shotCount) photos will be deleted.")
                }
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
    }

    private var topBar: some View {
        HStack {
            Button {
                isConfirmingCancel = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Brand.surface.opacity(0.85), in: Rectangle())
                    .overlay(
                        Rectangle()
                            .stroke(Brand.line, lineWidth: 1)
                    )
            }
            .tint(Brand.text)
            .accessibilityLabel(String(localized: "Cancel scan"))

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(engine.shotCount) photos")
                    .font(BrandFont.mono(13, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: engine.shotCount)
                HStack(spacing: 5) {
                    if engine.megapixels > 0 {
                        Text("\(engine.megapixels) MP")
                    }
                    if engine.isLocked {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(Brand.accent)
                    }
                    if engine.rejectedShots > 0 {
                        Text("· \(engine.rejectedShots) blurry")
                            .foregroundStyle(Brand.accentDeep)
                    }
                }
                .font(BrandFont.mono(11))
                .foregroundStyle(Brand.muted)
                if !engine.canFinish {
                    Text("at least \(TurntableCaptureEngine.minimumShots)")
                        .font(BrandFont.mono(11))
                        .foregroundStyle(Brand.muted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Brand.surface.opacity(0.85), in: Rectangle())
            .overlay(
                Rectangle()
                    .stroke(Brand.line, lineWidth: 1)
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
            if engine.isRecordingVideo {
                HStack(spacing: 8) {
                    PulsingDot()
                    Text("Recording video — rotate the turntable at a steady speed")
                        .font(BrandFont.mono(13))
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.center)
                }
            } else if engine.shouldChangeElevation {
                Label(
                    "One revolution done — change the phone's height or angle and shoot another",
                    systemImage: "arrow.up.and.down.circle.fill"
                )
                .font(BrandFont.mono(13, weight: .medium))
                .foregroundStyle(Brand.accentDeep)
                .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 8) {
                    if engine.isAutoCapturing {
                        PulsingDot()
                    }
                    Text(engine.isAutoCapturing
                         ? String(localized: "Auto-capture is on — keep rotating the object slowly")
                         : String(localized: "Rotate the object ~10° and shoot"))
                        .font(BrandFont.mono(13))
                        .foregroundStyle(Brand.muted)
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
                .disabled(engine.lockState == .locking || engine.lockState == .locked || engine.isRecordingVideo)

                Button(engine.isAutoCapturing ? String(localized: "Stop Auto") : String(localized: "Auto Capture")) {
                    engine.toggleAutoCapture()
                }
                .buttonStyle(BrandSecondaryButton())
                .disabled(engine.isRecordingVideo)

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
                .disabled(engine.isAutoCapturing || engine.isRecordingVideo)
                .overlay {
                    Rectangle()
                        .stroke(Brand.accent, lineWidth: 2)
                        .scaleEffect(rippleScale)
                        .opacity(rippleOpacity)
                }

                Button {
                    engine.toggleVideoRecording()
                } label: {
                    Image(systemName: engine.isRecordingVideo ? "stop.fill" : "video.fill")
                        .font(.title3)
                        .foregroundStyle(engine.isRecordingVideo ? Brand.signal : Brand.text)
                        .frame(width: 56, height: 48)
                        .accessibilityLabel(engine.isRecordingVideo
                            ? String(localized: "Stop recording video")
                            : String(localized: "Record video"))
                }
                .buttonStyle(BrandSecondaryButton())
                .disabled(engine.isAutoCapturing)
            }

            Button {
                finish()
            } label: {
                if isFinishing {
                    ProgressView().tint(Brand.onAccent)
                } else {
                    Text("Finish and Build Model")
                }
            }
            .buttonStyle(BrandPrimaryButton())
            .disabled(isFinishing || !engine.canFinish)

            if !engine.canFinish {
                Text("The solver needs at least \(TurntableCaptureEngine.minimumShots) photos to close the loop.")
                    .font(BrandFont.mono(11))
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .brandPanel()
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
        // The button's .disabled(isFinishing) lags one render behind rapid
        // taps: without this guard a second tap spawns a second finish()
        // task, the engine's reentrancy guard throws sessionUnavailable, and
        // the user gets a spurious "couldn't create the model" alert.
        guard !isFinishing else { return }
        isFinishing = true
        // @MainActor: isFinishing/finishError are @State, and the finish()
        // continuation must land back on the main thread to touch them.
        Task { @MainActor in
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
            .fill(Brand.accent)
            .frame(width: 8, height: 8)
            .brandGlow(radius: 8)
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

struct TurntableReconstructionView: View {
    let progress: ReconstructionProgress

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            RuneWatermark()
                .frame(width: 280, height: 280)

            VStack(spacing: 18) {
                ShimmerProgressBar(fraction: progress.fraction)
                    .frame(maxWidth: 240)

                Text(progress.stage?.displayName ?? String(localized: "Building model"))
                    .font(BrandFont.mono(17, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.text)
                    // The stage enum isn't Hashable; its raw value is a stable identity.
                    .id(progress.stage?.rawValue ?? -1)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                if let remaining = progress.remainingText {
                    Text("\(remaining) left")
                        .font(BrandFont.mono(15))
                        .foregroundStyle(Brand.muted)
                }
                Text("Don't background the app.")
                    .font(BrandFont.mono(13))
                    .foregroundStyle(Brand.muted)
            }
            .padding(28)
            .brandPanel()
            .padding(.horizontal, 40)
            .staggerIn(delay: 0.05)
        }
        .animation(.easeInOut(duration: 0.3), value: progress.stage?.rawValue ?? -1)
    }
}

/// Processing screen for a video take: measures the rotation, then extracts
/// the sharpest frame around each target angle before reconstruction.
struct TurntableVideoProcessingView: View {
    let progress: VideoProcessingProgress

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            RuneWatermark()
                .frame(width: 280, height: 280)

            VStack(spacing: 18) {
                ShimmerProgressBar(fraction: progress.fraction)
                    .frame(maxWidth: 240)

                Text(progress.stage ?? String(localized: "Processing video"))
                    .font(BrandFont.mono(17, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.text)
                    .id(progress.stage ?? "")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                Text("Don't background the app.")
                    .font(BrandFont.mono(13))
                    .foregroundStyle(Brand.muted)
            }
            .padding(28)
            .brandPanel()
            .padding(.horizontal, 40)
            .staggerIn(delay: 0.05)
        }
        .animation(.easeInOut(duration: 0.3), value: progress.stage ?? "")
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
                Rectangle()
                    .fill(Brand.text.opacity(0.12))
                Rectangle()
                    .fill(Brand.accent)
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
                    .clipShape(Rectangle())

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

struct TurntableResultView: View {
    let record: ScanRecord
    /// Surfaced next to the result rather than only logged: if masking was skipped
    /// the model will contain background, and that is worth knowing while looking
    /// at it.
    let warnings: [String]
    let onDone: () -> Void

    @Environment(ScanStorage.self) private var storage

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

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
                .clipShape(Rectangle())
                .overlay(
                    Rectangle()
                        .stroke(Brand.line, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 10)
                .staggerIn(delay: 0)

            VStack(spacing: 4) {
                Label("Scan ready", systemImage: "checkmark.circle.fill")
                    .font(BrandFont.mono(17, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.ok)
                if let count = record.imageCount {
                    Text("\(count) photos processed")
                        .font(BrandFont.mono(13))
                        .foregroundStyle(Brand.muted)
                }
                // The three numbers that explain the mesh: how many frames actually
                // got aligned, and how the cameras were spread around the object.
                if let summary = record.summary {
                    Text(summary)
                        .font(BrandFont.mono(12))
                        .foregroundStyle(Brand.muted)
                }
                if !record.isMetricallyScaled {
                    Text("Unscaled — no depth data")
                        .font(BrandFont.mono(12, weight: .medium))
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.accentDeep)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .brandPanel()
            .staggerIn(delay: 0.08)

            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "lightbulb.fill")
                    .font(BrandFont.mono(12))
                    .foregroundStyle(Brand.accentDeep)
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

struct TurntableMessageView: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(tint)
                Text(title)
                    .font(BrandFont.mono(17, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.text)
                Text(message)
                    .multilineTextAlignment(.center)
                    .font(BrandFont.mono(15))
                    .foregroundStyle(Brand.muted)
                Button("Close", action: onDismiss)
                    .buttonStyle(BrandPrimaryButton())
                    .padding(.horizontal, 40)
            }
            .padding(32)
            .brandPanel()
            .padding(.horizontal, 24)
            .staggerIn(delay: 0.05)
        }
    }
}

/// Draggable, pinchable rectangle marking the object.
struct ObjectMaskRectangle: View {
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
                .stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                .background(Brand.accent.opacity(0.06))
                .brandGlow(radius: 6)
                .frame(width: displayed.width, height: displayed.height)
                .position(x: displayed.midX, y: displayed.midY)
                .overlay(alignment: .topLeading) {
                    Text("object")
                        .font(BrandFont.mono(10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Brand.accent, in: Rectangle())
                        // The overlay is already anchored at the rect's
                        // top-leading corner, so offset in the overlay's own
                        // coordinates — positioning with displayed.minX/minY
                        // here applied the rect offset twice.
                        .offset(x: 22, y: -10)
                }
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { _ in
                            // Commit only the drag: a pinch still in flight
                            // keeps its own state instead of snapping when the
                            // other gesture ends mid-gesture.
                            frame = frame.offsetBy(dx: dragOffset.width, dy: dragOffset.height)
                            dragOffset = .zero
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { scale = $0.magnification }
                        .onEnded { _ in
                            // Commit only the pinch: a drag still in flight
                            // keeps its own state.
                            let width = frame.width * scale
                            let height = frame.height * scale
                            frame = CGRect(
                                x: frame.midX - width / 2,
                                y: frame.midY - height / 2,
                                width: width,
                                height: height
                            )
                            scale = 1
                        }
                )
        }
        .allowsHitTesting(true)
    }
}
