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
            Brand.bg.ignoresSafeArea()
            ScanlineOverlay()

            VStack(spacing: 20) {
                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    Text("VV Capture")
                        .font(BrandFont.mono(32, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.accentDeep)
                        .brandGlow()
                    Text("How are you capturing today?")
                        .font(BrandFont.mono(15))
                        .foregroundStyle(Brand.muted)
                }
                .padding(.bottom, 8)

                ForEach(ScanEngineKind.allCases) { kind in
                    modeCard(for: kind)
                }

                Spacer(minLength: 0)

                Text("Models build on-device with the existing photogrammetry pipeline.")
                    .font(BrandFont.mono(12))
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
    }

    private func modeCard(for kind: ScanEngineKind) -> some View {
        Button {
            onSelect(kind)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: kind == .turntable ? "rotate.3d" : "figure.walk.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 52, height: 52)
                    .background(Brand.accent.opacity(0.14), in: Rectangle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.displayName)
                        .font(BrandFont.mono(17, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.text)
                    Text(kind.tagline)
                        .font(BrandFont.mono(14))
                        .foregroundStyle(Brand.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Brand.muted)
            }
            .padding(16)
        }
        .brandPanel()
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
            Brand.bg.ignoresSafeArea()
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
}

/// C1 denial path: the user said no (or restricted) to camera access. Shows
/// the recovery copy from `CameraPermission.denialMessage` with a Settings
/// deep-link — the denial is recoverable without reinstalling.
private struct CameraPermissionDeniedView: View {
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "video.slash.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Brand.accent)
                Text(String(localized: "Camera access needed"))
                    .font(BrandFont.mono(17, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.text)
                Text(CameraPermission.denialMessage)
                    .multilineTextAlignment(.center)
                    .font(BrandFont.mono(14))
                    .foregroundStyle(Brand.muted)
                Button(String(localized: "Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(BrandPrimaryButton())
                .padding(.horizontal, 40)
                Button(String(localized: "Close"), action: onClose)
                    .font(BrandFont.mono(13, weight: .medium))
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.muted)
            }
            .padding(32)
            .brandPanel()
            .padding(.horizontal, 24)
        }
    }
}
