import SwiftUI

/// AR-style coverage overlay: a 3D-projected ring showing where in space each
/// image was taken, plus a notched circle tracking which sides are captured.
///
/// Deliberately *not* ARKit world tracking. The camera never moves, so the
/// capture geometry is fully known from a fixed viewpoint — no anchor
/// placement, no tracking drift, no calibration step. The ring is rendered in
/// 3/4 perspective over the live preview, which reads as AR and carries the
/// same information: frustum glyphs where frames were taken, bright notches
/// where sides are covered.
///
/// Angles are nominal until the yaw estimator lands: shot index N sits at
/// (N−1) × (360° / notchCount), matching the ~10°-per-shot guidance.
struct CoverageCard: View {
    let indices: [Int]
    let notchCount: Int

    private var covered: Int {
        Set(indices.map { ($0 - 1) % notchCount }).count
    }
    private var complete: Bool { covered >= notchCount }

    var body: some View {
        VStack(spacing: 2) {
            CoverageCanvas(indices: indices, notchCount: notchCount)
            Text(complete ? "Full turn complete" : "\(covered)/\(notchCount) sides")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(complete ? Brand.phosphorBright : Brand.textSecondary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: covered)
        }
        .padding(10)
        .depthPanel(cornerRadius: 14)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}

private struct CoverageCanvas: View {
    let indices: [Int]
    let notchCount: Int

    /// 0 → 1 while the newest frustum pops in.
    @State private var pulse: Double = 1

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let cy = size.height / 2 + 4
            let radius = min(size.width, size.height) / 2 - 16
            let squash: CGFloat = 0.42

            func point(atDegrees deg: Double, radius r: CGFloat) -> CGPoint {
                let rad = deg * .pi / 180
                return CGPoint(
                    x: cx + CGFloat(sin(rad)) * r,
                    y: cy - CGFloat(cos(rad)) * r * squash
                )
            }

            /// 0 = far side of the ring, 1 = near side.
            func depth(atDegrees deg: Double) -> CGFloat {
                CGFloat((1 - cos(deg * .pi / 180)) / 2)
            }

            let captured = Set(indices.map { ($0 - 1) % notchCount })
            let newest = indices.last

            // Turntable disc.
            let discRect = CGRect(
                x: cx - radius, y: cy - radius * squash,
                width: radius * 2, height: radius * 2 * squash
            )
            let disc = Path(ellipseIn: discRect)
            context.fill(disc, with: .color(Brand.panel))
            context.stroke(disc, with: .color(Brand.phosphor.opacity(0.25)), lineWidth: 1)

            // Orbit ring the virtual cameras sit on.
            let ringR = radius + 9
            let ringRect = CGRect(
                x: cx - ringR, y: cy - ringR * squash,
                width: ringR * 2, height: ringR * 2 * squash
            )
            context.stroke(
                Path(ellipseIn: ringRect),
                with: .color(.white.opacity(0.14)), lineWidth: 1
            )

            // Notch ticks: one slot per photo around the turn.
            for n in 0..<notchCount {
                let deg = Double(n) * 360 / Double(notchCount)
                var tick = Path()
                tick.move(to: point(atDegrees: deg, radius: ringR - 4))
                tick.addLine(to: point(atDegrees: deg, radius: ringR + 4))
                let hit = captured.contains(n)
                context.stroke(
                    tick,
                    with: .color(hit ? Brand.phosphor : .white.opacity(0.14)),
                    lineWidth: hit ? 2.5 : 1
                )
            }

            // Camera frustums, far to near so nearer glyphs overlap correctly.
            let ordered = indices.sorted {
                depth(atDegrees: angle(of: $0)) < depth(atDegrees: angle(of: $1))
            }
            for shot in ordered {
                let deg = angle(of: shot)
                let p = point(atDegrees: deg, radius: ringR)
                let d = depth(atDegrees: deg)
                let isNewest = shot == newest
                let pop = isNewest ? CGFloat(0.6 + 0.4 * pulse) : 1
                let alpha = 0.55 + 0.45 * d
                let glow = isNewest ? (1 - pulse) : 0

                // View-direction leader toward the product.
                var leader = Path()
                leader.move(to: p)
                leader.addLine(to: CGPoint(
                    x: cx + (p.x - cx) * 0.7,
                    y: cy + (p.y - cy) * 0.7
                ))
                context.stroke(
                    leader,
                    with: .color(Brand.phosphor.opacity(alpha)),
                    lineWidth: 1.5
                )

                // Frame glyph, larger when nearer.
                let glyphScale = pop * (0.7 + 0.5 * d)
                let w: CGFloat = 12 * glyphScale
                let h: CGFloat = 9 * glyphScale
                let rect = RoundedRectangle(cornerRadius: 2)
                    .path(in: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h))
                if glow > 0.01 {
                    context.stroke(
                        rect,
                        with: .color(Brand.phosphor.opacity(glow * 0.8)),
                        lineWidth: 3
                    )
                }
                context.stroke(
                    rect,
                    with: .color(Brand.phosphor.opacity(alpha)),
                    lineWidth: 1.5
                )
            }

            // The product at the center.
            let dot = Path(ellipseIn: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6))
            context.fill(dot, with: .color(Brand.phosphorBright))
        }
        .frame(height: 118)
        .onChange(of: indices.count) { _, _ in
            pulse = 0
            withAnimation(.spring(response: 0.45, dampingFraction: 0.5)) { pulse = 1 }
        }
    }

    private func angle(of shot: Int) -> Double {
        Double((shot - 1) % notchCount) * 360 / Double(notchCount)
    }
}
