import SwiftUI

/// Capture-mode picker: turntable vs phone orbit.
///
/// Shown at launch and after every finished scan, so switching technologies
/// is one tap. Each card states which side moves — the one decision that
/// matters.
struct CaptureModePicker: View {
    @Environment(ScanStorage.self) private var storage

    var onSelect: (ScanEngineKind) -> Void

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            VignetteOverlay()
            GrainOverlay(opacity: 0.035)

            VStack(spacing: 20) {
                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    Text("VV Capture")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("How are you capturing today?")
                        .font(.subheadline)
                        .foregroundStyle(Brand.textSecondary)
                }
                .padding(.bottom, 8)

                ForEach(ScanEngineKind.allCases) { kind in
                    modeCard(for: kind)
                }

                Spacer(minLength: 0)

                Text("Models build on-device with the existing photogrammetry pipeline.")
                    .font(.caption2)
                    .foregroundStyle(Brand.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .preferredColorScheme(.dark)
    }

    private func modeCard(for kind: ScanEngineKind) -> some View {
        Button {
            onSelect(kind)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: kind == .turntable ? "rotate.3d" : "figure.walk.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(Brand.phosphor)
                    .frame(width: 52, height: 52)
                    .background(Brand.phosphorDim, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.displayName)
                        .font(.headline)
                        .foregroundStyle(Brand.textPrimary)
                    Text(kind.tagline)
                        .font(.subheadline)
                        .foregroundStyle(Brand.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Brand.textTertiary)
            }
            .padding(16)
        }
        .depthPanel(cornerRadius: 18)
        .tiltParallax(magnitude: 4)
    }
}

/// App shell: mode picker, then the chosen capture flow. A finished scan
/// returns to the picker so switching technologies is one tap.
struct RootView: View {
    @State private var mode: ScanEngineKind?
    @State private var runID = UUID()
    @State private var showPermissionDenied = false

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            if let mode {
                flow(for: mode)
                    .id(runID)
                    .transition(.opacity)
            } else {
                CaptureModePicker { selected in
                    Task { await selectAfterPermission(selected) }
                }
                .transition(.opacity)
            }

            if showPermissionDenied {
                CameraPermissionDeniedView {
                    showPermissionDenied = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mode)
    }

    /// C1: ask for camera access before a flow is even created. The engines
    /// gate themselves on `CameraPermission.ensureVideoAccess()` as well, but
    /// asking up front keeps a denied user on the picker with a clear
    /// recovery path instead of bouncing through a flow that can't start.
    ///
    /// `@MainActor`: the permission prompt resolves off the main thread, and
    /// the `@State` writes below must happen back on it.
    @MainActor
    private func selectAfterPermission(_ kind: ScanEngineKind) async {
        if await CameraPermission.ensureVideoAccess() {
            mode = kind
        } else {
            showPermissionDenied = true
        }
    }

    @ViewBuilder
    private func flow(for mode: ScanEngineKind) -> some View {
        switch mode {
        case .turntable:
            TurntableFlowView { reset() }
        case .orbit:
            OrbitFlowView { reset() }
        }
    }

    private func reset() {
        mode = nil
        runID = UUID()
    }
}

#Preview {
    RootView()
        .environment(ScanStorage())
        .preferredColorScheme(.dark)
}

/// C1 denial path: the user said no (or restricted) to camera access. Shows
/// the recovery copy from `CameraPermission.denialMessage` with a Settings
/// deep-link — the denial is recoverable without reinstalling.
private struct CameraPermissionDeniedView: View {
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            GrainOverlay()

            VStack(spacing: 16) {
                Image(systemName: "video.slash.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Brand.phosphor)
                Text(String(localized: "Camera access needed"))
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                Text(CameraPermission.denialMessage)
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                Button(String(localized: "Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(BrandPrimaryButton())
                .padding(.horizontal, 40)
                Button(String(localized: "Close"), action: onClose)
                    .font(.footnote)
                    .foregroundStyle(Brand.textTertiary)
            }
            .padding(32)
            .depthPanel()
            .padding(.horizontal, 24)
        }
    }
}
