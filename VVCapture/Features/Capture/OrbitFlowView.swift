import AVFoundation
import SwiftUI

/// Capture flow for phone-orbit photogrammetry: product fixed, phone walked
/// around it.
///
/// One video take, gyro-tracked coverage ring, sharpest frames spread across
/// the take. Poses come from the solver — no yaw estimator involved.
struct OrbitFlowView: View {
    @Environment(ScanStorage.self) private var storage

    @State private var engine: OrbitCaptureEngine?
    @State private var finishedRecord: ScanRecord?
    @State private var startupError: String?

    /// Screen-space rectangle the user places over the object.
    @State private var maskFrame = CGRect(x: 80, y: 240, width: 220, height: 260)

    /// The capture overlay's origin in window coordinates — see
    /// OverlayWindowOriginKey (M26). The mask rect is shifted by this origin
    /// into window space before `MaskCoordinateSpace` converts it.
    @State private var overlayWindowOrigin = CGPoint.zero

    /// Called when the flow ends so the host can reset to a fresh session.
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
    private func content(for engine: OrbitCaptureEngine) -> some View {
        switch engine.phase {
        case .idle, .preparing:
            ProgressView("Preparing camera…").tint(Brand.phosphor)

        case .capturing:
            captureStage(engine: engine)

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
                tint: Brand.danger
            ) { onFinished() }

        case .cancelled:
            Color.clear.task { onFinished() }
        }
    }

    private func captureStage(engine: OrbitCaptureEngine) -> some View {
        ZStack {
            if let session = engine.session {
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

            VignetteOverlay()
            GrainOverlay(opacity: 0.035)

            ObjectMaskRectangle(frame: $maskFrame)

            OrbitOverlay(engine: engine) {
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
        let engine = OrbitCaptureEngine(storage: storage)
        do {
            try await engine.start()
            self.engine = engine
        } catch {
            startupError = error.localizedDescription
        }
    }
}

// MARK: - Orbit overlay

private struct OrbitOverlay: View {
    let engine: OrbitCaptureEngine
    let onCancel: () -> Void

    @State private var isFinishing = false
    @State private var isConfirmingCancel = false
    @State private var finishError: String?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
            HStack {
                OrbitCoverageCard(
                    coveredBins: engine.coveredYawBins,
                    binCount: OrbitCaptureEngine.yawBinCount,
                    isRecording: engine.isRecordingVideo
                )
                .frame(width: 156)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            Spacer(minLength: 0)
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
            // M30: the X button sat under the Dynamic Island and Finish under
            // the home indicator on the 15 Pro Max — respect the real insets.
            .padding(.top, geo.safeAreaInsets.top)
            .padding(.bottom, geo.safeAreaInsets.bottom + 8)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: engine.phase)
            .confirmationDialog("Cancel the scan?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
                Button("Discard and Exit", role: .destructive, action: onCancel)
                Button("Back to Scan", role: .cancel) {}
            } message: {
                Text("The recorded video will be deleted.")
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
                    .background(Brand.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Brand.panelEdge, lineWidth: 1)
                    )
            }
            .accessibilityLabel(String(localized: "Cancel scan"))
            Spacer(minLength: 0)
            if engine.isRecordingVideo {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Brand.danger)
                        .frame(width: 8, height: 8)
                    Text("REC")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.danger)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Brand.panel.opacity(0.85), in: Capsule())
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            Text(guidanceText)
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    engine.toggleVideoRecording()
                } label: {
                    Image(systemName: engine.isRecordingVideo ? "stop.fill" : "video.fill")
                        .font(.title3)
                        .foregroundStyle(engine.isRecordingVideo ? Brand.danger : Brand.textPrimary)
                        .frame(width: 56, height: 48)
                        .accessibilityLabel(engine.isRecordingVideo
                            ? String(localized: "Stop recording video")
                            : String(localized: "Record video"))
                }
                .buttonStyle(BrandSecondaryButton())
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
                Text("Record a video of the product first.")
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
    }

    private var guidanceText: String {
        // String(localized:): this property returns String (not a literal), so
        // the strings must be localized at creation — Text(guidanceText) would
        // otherwise display the untranslated key.
        if engine.isRecordingVideo {
            engine.isOrbitComplete
                ? String(localized: "Full orbit covered — stop when you're happy with the angles")
                : String(localized: "Walk slowly around the product — keep it centered in the frame")
        } else if engine.recordedVideoURL != nil {
            String(localized: "Take recorded — finish to build the model, or record again")
        } else {
            String(localized: "Frame the product, hit record, then walk all the way around it")
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
                if case ScanEngineError.cancelled = error { return }
                finishError = error.localizedDescription
            }
        }
    }
}