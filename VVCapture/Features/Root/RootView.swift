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

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            if let mode {
                flow(for: mode)
                    .id(runID)
                    .transition(.opacity)
            } else {
                CaptureModePicker { selected in
                    mode = selected
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mode)
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
