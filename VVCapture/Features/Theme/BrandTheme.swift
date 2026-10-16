import CoreMotion
import SwiftUI

/// Amber-phosphor-on-near-black brand system, shared by every screen.
///
/// Follows the app-icon direction (Elder Futhark rune, #FF7A18 on #100C07):
/// square-ish corners, glow only on accents, texture over flat color.
/// Everything here is flow-agnostic — it survives the stills-to-video rework.
enum Brand {
    /// Amber phosphor. Reserved for accents, primary actions, live states.
    static let phosphor = Color(red: 1.0, green: 0.478, blue: 0.094) // #FF7A18
    static let phosphorBright = Color(red: 1.0, green: 0.66, blue: 0.28)
    static let phosphorDim = Color(red: 1.0, green: 0.478, blue: 0.094).opacity(0.16)
    /// Warm near-black. The app background — never pure black.
    static let ink = Color(red: 0.063, green: 0.047, blue: 0.027) // #100C07
    static let panel = Color(red: 0.115, green: 0.088, blue: 0.062)
    static let panelEdge = Color.white.opacity(0.09)
    static let textPrimary = Color(white: 0.96)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.42)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.28)
    static let ok = Color(red: 0.42, green: 0.92, blue: 0.55)
}

// MARK: - Texture

/// Static film grain. Deterministic seed so it never shimmers between redraws.
struct GrainOverlay: View {
    var opacity: Double = 0.05

    var body: some View {
        Canvas { context, size in
            var rng = LCGRandom(seed: 0x9E3779B9)
            let count = Int(size.width * size.height / 1100)
            for _ in 0..<count {
                let x = CGFloat(rng.next()) / CGFloat(UInt64.max) * size.width
                let y = CGFloat(rng.next()) / CGFloat(UInt64.max) * size.height
                let white = rng.next() % 2 == 0
                context.fill(
                    Path(CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(white ? .white : .black)
                )
            }
        }
        .opacity(opacity)
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }
}

/// Deterministic pseudo-random generator for stable texture.
private struct LCGRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Soft darkening toward the edges — the other half of the 2.5D read.
struct VignetteOverlay: View {
    var body: some View {
        RadialGradient(
            gradient: Gradient(colors: [.clear, .black.opacity(0.5)]),
            center: .center,
            startRadius: 140,
            endRadius: 850
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 2.5D depth

/// A panel with a hard amber-tinted under-layer offset behind it: the 2.5D
/// "lifted card" read, without any real 3D.
struct DepthPanel: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Brand.phosphor.opacity(0.14))
                    .offset(x: 2.5, y: 3.5)
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Brand.panel)
                    .shadow(color: .black.opacity(0.55), radius: 16, x: 0, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Brand.panelEdge, lineWidth: 1)
            )
    }
}

extension View {
    /// 2.5D lifted panel.
    func depthPanel(cornerRadius: CGFloat = 16) -> some View {
        modifier(DepthPanel(cornerRadius: cornerRadius))
    }

    /// The one sanctioned glow: accents only.
    func phosphorGlow(radius: CGFloat = 14, opacity: Double = 0.35) -> some View {
        shadow(color: Brand.phosphor.opacity(opacity), radius: radius)
    }
}

/// Staggered entrance: fades and rises in after `delay`.
struct StaggerIn: ViewModifier {
    var delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    func staggerIn(delay: Double = 0) -> some View {
        modifier(StaggerIn(delay: delay))
    }
}

/// Subtle 2.5D tilt parallax from device motion. Degrades to zero where there
/// is no motion data (simulator) — never a hard dependency.
struct TiltParallax: ViewModifier {
    var magnitude: CGFloat = 7
    @State private var offset = CGSize.zero
    @State private var manager: CMMotionManager?

    func body(content: Content) -> some View {
        content
            .offset(offset)
            .onAppear(perform: start)
            .onDisappear(perform: stop)
    }

    private func start() {
        let manager = CMMotionManager()
        guard manager.isDeviceMotionAvailable else { return }
        self.manager = manager
        manager.deviceMotionUpdateInterval = 1 / 30
        manager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let attitude = motion?.attitude else { return }
            let x = CGFloat(attitude.roll).clamped(to: -0.35...0.35) / 0.35
            let y = CGFloat(attitude.pitch).clamped(to: -0.35...0.35) / 0.35
            withAnimation(.easeOut(duration: 0.25)) {
                offset = CGSize(width: -x * magnitude, height: y * magnitude)
            }
        }
    }

    private func stop() {
        manager?.stopDeviceMotionUpdates()
        manager = nil
    }
}

extension View {
    func tiltParallax(magnitude: CGFloat = 7) -> some View {
        modifier(TiltParallax(magnitude: magnitude))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Stylised Raidho rune — the app icon's glyph — as a background watermark.
/// Abstract enough to read as texture at 5% opacity.
struct RuneWatermark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            Path { path in
                // Stem.
                path.move(to: CGPoint(x: 0.32 * s, y: 0.18 * s))
                path.addLine(to: CGPoint(x: 0.32 * s, y: 0.82 * s))
                // Bowl.
                path.move(to: CGPoint(x: 0.32 * s, y: 0.18 * s))
                path.addCurve(
                    to: CGPoint(x: 0.32 * s, y: 0.5 * s),
                    control1: CGPoint(x: 0.74 * s, y: 0.2 * s),
                    control2: CGPoint(x: 0.74 * s, y: 0.48 * s)
                )
                // Leg.
                path.move(to: CGPoint(x: 0.38 * s, y: 0.5 * s))
                path.addLine(to: CGPoint(x: 0.68 * s, y: 0.82 * s))
            }
            .stroke(Brand.phosphor.opacity(0.055), lineWidth: max(2, s * 0.035))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Buttons

struct BrandPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                Brand.phosphor.opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .phosphorGlow(
                radius: configuration.isPressed ? 6 : 14,
                opacity: configuration.isPressed ? 0.2 : 0.35
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct BrandSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Brand.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.14 : 0.07),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Brand.phosphor.opacity(0.35), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
