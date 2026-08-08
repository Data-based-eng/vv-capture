import Foundation
import RealityKit
import simd

/// What the solver actually managed to do with the captured images.
///
/// Exists because "kalite kötü" is not a diagnosis. A soft, mushy mesh has three
/// very different causes and they need different fixes:
///
/// 1. Most images never got aligned → the solve is running on a fraction of the
///    input, and no reconstruction setting will help.
/// 2. Horizontal coverage is short of a full turn → whole sides are missing.
/// 3. Every camera sits at the same height → the camera centres lie on a single
///    circle, which gives almost no vertical parallax. This is the classic reason
///    a turntable pass loses to a hand-held orbit even with the same shot count,
///    because a walking human naturally varies elevation and a tripod does not.
///
/// `PhotogrammetrySession.Request.poses` reports the solved camera transforms, so
/// all three are measurable rather than guessable.
struct PoseDiagnostics: Sendable {

    /// Where the cameras sit relative to what is being reconstructed.
    ///
    /// This changes which measurements mean anything at all. Orbiting an object puts
    /// the cameras on a shell around it, so their direction from the centre is a
    /// real coverage measure. Walking through a room puts them *inside* the volume
    /// looking outward, and some of them pass close to the centroid — where the
    /// direction is numerically meaningless. Reporting angles there produced
    /// healthy-looking numbers for a capture whose problem was somewhere else
    /// entirely, which is worse than reporting nothing.
    enum Framing: Sendable {
        /// Cameras surround the subject.
        case orbit
        /// Cameras are inside the subject.
        case interior
    }

    let framing: Framing
    /// Images the solver placed in space.
    let solvedSamples: Int
    /// Images handed to it.
    let totalSamples: Int
    /// How much of a full turn the solved cameras cover, in degrees. Only
    /// meaningful for `.orbit`.
    let azimuthCoverageDegrees: Int
    /// Difference between the highest and lowest camera elevation, in degrees. Only
    /// meaningful for `.orbit`.
    let elevationSpreadDegrees: Int

    /// Azimuth is binned rather than measured min-to-max: cameras spread over
    /// 350° and cameras clustered in two opposite clumps have the same extent but
    /// very different coverage.
    private static let azimuthBinCount = 24

    init(poses: PhotogrammetrySession.Poses, totalSamples: Int, framing: Framing) {
        let positions = poses.posesBySample.values.map(\.translation)
        solvedSamples = positions.count
        self.totalSamples = totalSamples
        self.framing = framing

        guard framing == .orbit else {
            azimuthCoverageDegrees = 0
            elevationSpreadDegrees = 0
            return
        }

        guard positions.count >= 2 else {
            azimuthCoverageDegrees = 0
            elevationSpreadDegrees = 0
            return
        }

        // For an orbit the cameras sit on a shell around the subject, so their
        // centroid approximates the subject's centre closely enough to measure
        // angles from.
        let centroid = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)

        var occupiedBins = Set<Int>()
        var minimumElevation = Float.greatestFiniteMagnitude
        var maximumElevation = -Float.greatestFiniteMagnitude

        for position in positions {
            let offset = position - centroid
            let length = simd_length(offset)
            guard length > 1e-5 else { continue }

            // RealityKit is Y-up: the horizontal ring lives in X/Z.
            let azimuth = atan2(offset.z, offset.x)
            let normalised = (azimuth + .pi) / (2 * .pi)
            let bin = min(Self.azimuthBinCount - 1, Int(normalised * Float(Self.azimuthBinCount)))
            occupiedBins.insert(bin)

            let elevation = asin(max(-1, min(1, offset.y / length)))
            minimumElevation = min(minimumElevation, elevation)
            maximumElevation = max(maximumElevation, elevation)
        }

        let degreesPerBin = 360 / Self.azimuthBinCount
        azimuthCoverageDegrees = occupiedBins.count * degreesPerBin

        if maximumElevation >= minimumElevation {
            let spread = (maximumElevation - minimumElevation) * 180 / .pi
            elevationSpreadDegrees = Int(spread.rounded())
        } else {
            elevationSpreadDegrees = 0
        }
    }

    /// One line for the library row. Angles are omitted where they mean nothing.
    var summaryText: String {
        let alignment = "\(solvedSamples)/\(totalSamples) hizalandı"
        guard framing == .orbit else { return alignment }
        return "\(alignment) · yatay \(azimuthCoverageDegrees)° · dikey \(elevationSpreadDegrees)°"
    }

    /// The reason the mesh looks the way it does, when the numbers say so.
    ///
    /// Ordered worst-first: an unaligned majority makes everything else moot.
    var advice: [String] {
        var notes: [String] = []

        if totalSamples > 0, solvedSamples < (totalSamples * 4) / 5 {
            let dropped = totalSamples - solvedSamples
            // The failure is the same, the cause is not: a rotating subject loses
            // frames to sliding shadows, a walking camera loses them to motion blur.
            // One piece of advice for both would be wrong half the time.
            switch framing {
            case .orbit:
                notes.append("\(dropped) fotoğraf hizalanamadı ve modele hiç girmedi. En yaygın sebebi ışığın objeyle birlikte dönmesi: obje çevrilirken yüzeydeki gölge kayıyor, çözücü aynı noktayı iki karede eşleştiremiyor. Işığı her yönden yumuşak yap veya lambayı objeyle birlikte döndür.")
            case .interior:
                notes.append("\(dropped) kare hizalanamadı ve modele hiç girmedi — karelerin yalnızca %\(totalSamples > 0 ? solvedSamples * 100 / totalSamples : 0)'i kullanıldı. Yürürken en yaygın sebep hareket bulanıklığı ve hızlı dönüş: telefonu çevirirken bir an durakla, ışığı artır. Bomboş düz duvarlar da eşleşecek desen bırakmaz.")
            }
        }

        switch framing {
        case .orbit:
            if azimuthCoverageDegrees < 300 {
                notes.append("Yatay kapsama \(azimuthCoverageDegrees)° — tam tur kapanmamış. Kapanmayan tarafta yüzey uydurma çıkar.")
            }

            // The single-ring case. Worth stating even when everything else is fine,
            // because it is the difference between a turntable pass and an orbit.
            if elevationSpreadDegrees < 15 {
                notes.append("Bütün kareler neredeyse aynı yükseklikten (\(elevationSpreadDegrees)° dikey yayılım). Tek halka üzerindeki kameralar dikey paralaks vermez; üst ve alt yüzeyler bu yüzden yumuşuyor. Telefonun yüksekliğini/açısını değiştirip ikinci bir tur çekmek en büyük tek iyileştirme.")
            }

        case .interior:
            // Stated unconditionally, and it is not a capture problem: `reduced` is a
            // fixed budget per model, so a whole room gets the same ~25.000 triangles
            // and the same single texture that a game controller gets. At room scale
            // that is roughly one triangle per 20 cm² — no amount of walking fixes it.
            if solvedSamples >= (totalSamples * 4) / 5 {
                notes.append(String(localized: "Çekim iyi: kareler hizalandı. Kalitenin düşük kalmasının sebebi çekim değil, cihaz üstü `reduced` seviyesi — oda ölçeğinde ~25.000 üçgen ve tek texture bütün yüzeye yayılıyor. Bir obje için bol, bir oda için çok az. Kareler saklandı: Mac'te `.raw` ile yeniden işlemek tek gerçek çözüm."))
            }
        }

        return notes
    }
}
