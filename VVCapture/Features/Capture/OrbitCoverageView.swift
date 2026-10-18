import SwiftUI

/// Orbit-mode coverage: a ring that fills as the gyro-tracked yaw sweeps
/// around the product. 72 sectors of 5°; covered sectors glow amber, the rest
/// sit dim. Same brand language as the turntable coverage card.
struct OrbitCoverageCard: View {
    /// Yaw sectors covered since the recording started.
    var coveredBins: Set<Int>
    var binCount: Int = 72
    var isRecording: Bool = false

    private var coverageDegrees: Double {
        Double(coveredBins.count) * (360 / Double(binCount))
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                ForEach(0..<binCount, id: \.self) { bin in
                    let angle = Double(bin) / Double(binCount) * 360
                    let covered = coveredBins.contains(bin)
                    Rectangle()
                        .fill(covered ? Brand.accent : Brand.accent.opacity(0.16))
                        .frame(width: 3, height: covered ? 12 : 8)
                        .offset(y: -52)
                        .rotationEffect(.degrees(angle))
                        .shadow(color: covered ? Brand.accent.opacity(0.7) : .clear, radius: 4)
                }
                // Direction hint: the gap at the top is where you started.
                if isRecording {
                    Circle()
                        .fill(Brand.signal)
                        .frame(width: 8, height: 8)
                        .offset(y: -52)
                }
                VStack(spacing: 2) {
                    Text("\(Int(coverageDegrees))°")
                        .font(BrandFont.mono(22, weight: .bold))
                        .foregroundStyle(Brand.accent)
                    // String(localized:): the ternary resolves to String, not a
                    // LocalizedStringKey, so the strings are localized at creation.
                    Text(coveredBins.count >= binCount
                        ? String(localized: "Full orbit")
                        : String(localized: "of 360°"))
                        .font(BrandFont.mono(11, weight: .medium))
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.muted)
                }
            }
            .frame(width: 132, height: 132)
            .animation(.easeOut(duration: 0.3), value: coveredBins)
        }
        .padding(12)
        .brandPanel()
        // VoiceOver reads one summary instead of 72 unlabeled segments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        // String(localized:): this property returns String, so the strings are
        // localized at creation — the label would otherwise show the raw key.
        coveredBins.count >= binCount
            ? String(localized: "Full orbit covered")
            : String(localized: "\(Int(coverageDegrees)) of 360 degrees covered")
    }
}
