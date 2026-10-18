import CoreText
import SwiftUI
#if os(iOS)
import CoreMotion
#endif

/// coresapian inc. brand bible v1.0 — the paper/screen token system.
///
/// Light = warm paper: rust accents, clean sheet, no glow.
/// Dark = orange-phosphor screen: phosphor accents, CRT scanlines,
/// glow on display type only.
///
/// The two ramps never mix on one surface. Body text is never the action
/// color; coral is signal-only; backgrounds stay warm (never pure black).
enum Brand {
    // MARK: - Tokens (dynamic: paper in light, screen in dark)

    /// Page background. Aged Paper #EFE4CD / Abyss #090704.
    static let bg = dynamic(light: 0xEFE4CD, dark: 0x090704)
    /// Panels and cards. Warm Paper #F7EEDC / Screen #100C07.
    static let surface = dynamic(light: 0xF7EEDC, dark: 0x100C07)
    /// Recessed fields: tab bars, input wells. Parchment Deep #E5D4B5 /
    /// Ember Field #191007.
    static let surface2 = dynamic(light: 0xE5D4B5, dark: 0x191007)
    /// Body text. Ember Brown #39220F / Signal Amber #FFB45F.
    static let text = dynamic(light: 0x39220F, dark: 0xFFB45F)
    /// Secondary text: hints, captions, metadata. #755433 / Muted Ember #BE7A35.
    static let muted = dynamic(light: 0x755433, dark: 0xBE7A35)
    /// Structural 1px borders — the grid etched into the terminal. #9F7141 /
    /// #6D350D.
    static let line = dynamic(light: 0x9F7141, dark: 0x6D350D)
    /// The one action color. Rust #BD4B0B / Phosphor #FF7A18.
    static let accent = dynamic(light: 0xBD4B0B, dark: 0xFF7A18)
    /// Headings. Deep Rust #7B2E05 / Signal Amber #FFB45F.
    static let accentDeep = dynamic(light: 0x7B2E05, dark: 0xFFB45F)
    /// Soft tinted fills: notice wells, active washes. #EDC79A / #2B1508.
    static let accentSoft = dynamic(light: 0xEDC79A, dark: 0x2B1508)
    /// Focus rings, peak highlights. #9B3B05 / Phosphor Pale #FFD09A.
    static let focus = dynamic(light: 0x9B3B05, dark: 0xFFD09A)
    /// Success and ready states. #6F4B12 / Pale Amber #FFC47C.
    static let ok = dynamic(light: 0x6F4B12, dark: 0xFFC47C)
    /// Errors, destructive actions, unconfirmed states. #C94B32 /
    /// Coral Signal #EF765E. Never decorative.
    static let signal = dynamic(light: 0xC94B32, dark: 0xEF765E)
    /// Ink set on top of accent fills — the primary button's text.
    /// Forge Brown #1B0B02, both modes.
    static let onAccent = Color(hex: 0x1B0B02)

    /// A dynamic color that resolves against the current interface style,
    /// so the app follows the system appearance with no per-view switching.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #endif
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Type

/// IBM Plex Mono, weights 400–700 — the single brand typeface. Bundled in
/// `VVCapture/Fonts` and registered via `UIAppFonts`.
///
/// The google/fonts cuts name Medium and SemiBold as their own families
/// ("IBM Plex Mono Medium", "IBM Plex Mono SemiBold"), so weights map to
/// explicit family names instead of relying on `.weight()` selection.
enum BrandFont {
    /// - Parameters:
    ///   - size: point size.
    ///   - weight: `.regular` (400), `.medium` (500), `.semibold` (600),
    ///     `.bold` (700). Other weights snap to the nearest shipped face.
    ///   - relativeTo: text style for Dynamic Type scaling.
    /// Registers the bundled faces with this process. Called once from the
    /// app entry point; safe to call repeatedly. If a face is missing the
    /// system monospaced face is the silent fallback.
    static func register() {
        for name in [
            "IBMPlexMono-Regular",
            "IBMPlexMono-Medium",
            "IBMPlexMono-SemiBold",
            "IBMPlexMono-Bold",
        ] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }

    static func mono(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo: Font.TextStyle = .body
    ) -> Font {
        switch weight {
        case .medium:
            return Font.custom("IBM Plex Mono Medium", size: size, relativeTo: relativeTo)
        case .semibold:
            return Font.custom("IBM Plex Mono SemiBold", size: size, relativeTo: relativeTo)
        case .bold, .heavy, .black:
            return Font.custom("IBM Plex Mono", size: size, relativeTo: relativeTo).weight(.bold)
        default:
            return Font.custom("IBM Plex Mono", size: size, relativeTo: relativeTo)
        }
    }
}

/// Structural heading: "> " prefix in accent, uppercase, semibold, head
/// color. The prefix is generated, never typed at the call site.
struct BrandHeading: View {
    let text: LocalizedStringKey
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            Text("> ")
                .foregroundStyle(Brand.accent)
            Text(text)
                .foregroundStyle(Brand.accentDeep)
        }
        .font(BrandFont.mono(size, weight: .semibold))
        .textCase(.uppercase)
        .brandGlow()
    }
}

/// Field label: "// " prefix in accent, uppercase, semibold.
struct BrandLabel: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 0) {
            Text("// ")
                .foregroundStyle(Brand.accent)
            Text(text)
                .foregroundStyle(Brand.accentDeep)
        }
        .font(BrandFont.mono(13, weight: .semibold))
        .textCase(.uppercase)
    }
}

// MARK: - Texture

/// CRT scanline field: 3px transparent, 1px accent at ~3%. Screen (dark)
/// only — paper documents stay clean.
struct ScanlineOverlay: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            Canvas { context, size in
                let scan = Brand.accent.opacity(0.032)
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(
                        Path(CGRect(x: 0, y: y + 3, width: size.width, height: 1)),
                        with: .color(scan)
                    )
                    y += 4
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Stylised Raidho rune — the app icon's glyph — as a background watermark.
/// A mark of station: it never carries meaning without a text label beside
/// it, and at 5% opacity it reads as texture.
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
            .stroke(Brand.accent.opacity(0.055), lineWidth: max(2, s * 0.035))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Panels and glow

/// The bible's panel: 1px line border, surface fill, warm shallow shadow.
/// Square corners — the terminal does not round them.
struct BrandPanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Brand.surface)
            .overlay(Rectangle().stroke(Brand.line, lineWidth: 1))
            .shadow(
                color: scheme == .dark
                    ? Color.black.opacity(0.5)
                    : Color(hex: 0x48270A).opacity(0.16),
                radius: scheme == .dark ? 16 : 14,
                x: 0,
                y: scheme == .dark ? 8 : 9
            )
    }
}

extension View {
    /// 1px line border on surface. Square.
    func brandPanel() -> some View {
        modifier(BrandPanel())
    }
}

/// The one sanctioned glow: display headings and marks only, screen mode
/// only. Body text never glows; paper never glows.
struct BrandGlow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 16

    func body(content: Content) -> some View {
        content.shadow(
            color: scheme == .dark ? Brand.accent.opacity(0.38) : .clear,
            radius: radius
        )
    }
}

extension View {
    /// Phosphor glow for display type and marks. Dark only by construction.
    func brandGlow(radius: CGFloat = 16) -> some View {
        modifier(BrandGlow(radius: radius))
    }
}

/// The hot edge of the screen: a 3px accent top rule for masthead cards.
struct AccentTopRule: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Brand.accent)
            .frame(height: 3)
            .shadow(
                color: scheme == .dark ? Brand.accent.opacity(0.6) : .clear,
                radius: 8
            )
    }
}

// MARK: - Badges and notices

/// Step chips and status marks. Uppercase micro type; the rune rides beside
/// a text label, never alone.
struct BrandBadge: View {
    enum Tone {
        /// 1px line border, head text.
        case plain
        /// Accent fill, forge-brown ink.
        case solid
        /// Dashed signal border, signal text — unconfirmed, error, destructive.
        case signal
    }

    let text: LocalizedStringKey
    var tone: Tone = .plain
    /// A mark of station, e.g. "ᛉ". Nil for plain step chips.
    var rune: String?

    var body: some View {
        HStack(spacing: 4) {
            if let rune {
                Text(rune).foregroundStyle(Brand.accent)
            }
            Text(text)
        }
        .font(BrandFont.mono(11, weight: .semibold))
        .textCase(.uppercase)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(foreground)
        .background(background)
        .overlay(border)
    }

    private var foreground: Color {
        switch tone {
        case .plain: Brand.accentDeep
        case .solid: Brand.onAccent
        case .signal: Brand.signal
        }
    }

    @ViewBuilder
    private var background: some View {
        switch tone {
        case .solid: Brand.accent
        default: Color.clear
        }
    }

    @ViewBuilder
    private var border: some View {
        switch tone {
        case .signal:
            Rectangle().stroke(Brand.signal, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .solid:
            EmptyView()
        case .plain:
            Rectangle().stroke(Brand.line, lineWidth: 1)
        }
    }
}

/// Dashed notice well on accent-soft. For copy that must be noticed but is
/// not an error — authorization boundaries, readiness notes.
struct BrandNotice<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(BrandFont.mono(14))
            .foregroundStyle(Brand.text)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.accentSoft)
            .overlay(Rectangle().stroke(Brand.line, style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
    }
}

// MARK: - Motion

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

#if os(iOS)
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
#endif

// MARK: - Buttons

/// Primary: fills the one action color with forge-brown ink. Brackets are
/// generated, never typed. Uppercase.
struct BrandPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            Text("[ ")
            configuration.label
            Text(" ]")
        }
        .font(BrandFont.mono(14, weight: .semibold))
        .textCase(.uppercase)
        .foregroundStyle(Brand.onAccent)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Brand.accent.opacity(configuration.isPressed ? 0.75 : 1))
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .opacity(isEnabled ? 1 : 0.38)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary: surface fill, 1px line border. Brackets generated. Uppercase.
struct BrandSecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            Text("[ ")
                .foregroundStyle(Brand.accent)
            configuration.label
            Text(" ]")
                .foregroundStyle(Brand.accent)
        }
        .font(BrandFont.mono(14, weight: .semibold))
        .textCase(.uppercase)
        .foregroundStyle(Brand.text)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Brand.surface.opacity(configuration.isPressed ? 0.7 : 1))
        .overlay(Rectangle().stroke(Brand.line, lineWidth: 1))
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .opacity(isEnabled ? 1 : 0.38)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
