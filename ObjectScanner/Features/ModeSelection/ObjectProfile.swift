import Foundation

/// What the user tells us about the object before scanning.
///
/// The app asks about the *object*, never "TrueDepth or photogrammetry?" — the
/// mode names mean nothing to someone holding a shoe, and picking wrong wastes
/// several minutes of capture and reconstruction.
struct ObjectProfile: Equatable {
    var size: Size = .small
    var finish: Finish = .matte
    var pattern: Pattern = .some

    enum Size: String, CaseIterable, Identifiable {
        case tiny, small, medium, large
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .tiny: String(localized: "5 cm'den küçük")
            case .small: String(localized: "5 – 30 cm")
            case .medium: String(localized: "30 cm – 1 m")
            case .large: String(localized: "1 m'den büyük")
            }
        }
    }

    enum Finish: String, CaseIterable, Identifiable {
        case matte, satin, glossy
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .matte: String(localized: "Mat")
            case .satin: String(localized: "Yarı parlak")
            case .glossy: String(localized: "Parlak / metalik")
            }
        }
    }

    enum Pattern: String, CaseIterable, Identifiable {
        case rich, some, none
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .rich: String(localized: "Bol desen / doku")
            case .some: String(localized: "Biraz var")
            case .none: String(localized: "Düz tek renk")
            }
        }
    }
}

struct ModeRecommendation: Equatable {
    enum Strength: Equatable {
        /// The chosen mode is clearly right for this object.
        case strong
        /// It will work, but the object fights the technique.
        case qualified
        /// The genuinely better tool is not available on this build/device.
        case fallback
    }

    let kind: ScanEngineKind
    let strength: Strength
    let rationale: String
    var warnings: [String] = []
    var tips: [String] = []
}

extension ObjectProfile {

    /// Picks a mode and explains itself.
    ///
    /// The decisive input is `pattern`, not `size`: photogrammetry derives
    /// geometry *from* surface detail, so a featureless object starves it no
    /// matter how well lit or how many photos are taken. That is exactly the case
    /// TrueDepth's active illumination is for.
    func recommendation(availableKinds: Set<ScanEngineKind>) -> ModeRecommendation {
        let trueDepthUsable = availableKinds.contains(.trueDepth)

        var warnings: [String] = []
        var tips: [String] = []

        if finish == .glossy {
            warnings.append(String(localized: "Parlak ve metalik yüzeyler her iki yöntemi de zorlar: yansıma açıyla değiştiği için eşleşme kurulamaz."))
            tips.append(String(localized: "Objeyi geçici olarak matlaştırın — talk pudrası, kuru şampuan veya mat tarama spreyi belirgin fark yaratır."))
        }

        if size == .tiny {
            warnings.append(String(localized: "5 cm'in altındaki objeler her iki sensörün de çözünürlük sınırına girer."))
            tips.append(String(localized: "Objeyi dokulu bir zemine koyup kadrajı sıkı tutun; çok küçük parçalar için masaüstü tarayıcı gerekir."))
        }

        if size == .large {
            tips.append(String(localized: "Büyük objede tek geçiş yetmez: farklı yüksekliklerde 2-3 yörünge çekin."))
        }

        // A turntable only helps when the object is small enough to sit on one and
        // light enough to reposition — otherwise orbiting is strictly easier.
        if size == .tiny || size == .small {
            tips.append(String(localized: "Döner tabla modu bu boyutta işe yarar: telefonu sabitleyip objeyi çevirmek daha kararlı sonuç verir. Düz, desensiz bir arka plan şart."))
        }

        // Featureless surface → depth sensing is the right tool.
        if pattern == .none {
            if trueDepthUsable {
                return ModeRecommendation(
                    kind: .trueDepth,
                    strength: size == .tiny ? .qualified : .strong,
                    rationale: String(localized: "Obje düz ve desensiz. Fotogrametri geometriyi yüzey deseninden türetir, desen yoksa mesh yumuşayıp detay kaybolur. TrueDepth aktif IR aydınlatma yaptığı için görünümden bağımsız ölçüm alır."),
                    warnings: warnings,
                    tips: tips
                )
            }

            warnings.append(String(localized: "Bu obje için doğru araç TrueDepth modu, ancak o mod henüz gelmedi (Faz 2)."))
            tips.append(String(localized: "Geçici çözüm: objeye silinebilir işaretler koyun — kurşun kalem noktaları, düşük yapışkanlı bant parçaları veya üzerine desenli bir örtü. Fotogrametriye eşleşecek özellik vermek yeterli."))
            return ModeRecommendation(
                kind: .objectCapture,
                strength: .fallback,
                rationale: String(localized: "Desensiz yüzeyde fotogrametri zorlanır, ama şu an mevcut olan tek mod bu."),
                warnings: warnings,
                tips: tips
            )
        }

        // Matte black is the classic IR failure: the surface swallows the dot
        // pattern and leaves holes. Photogrammetry only needs enough light.
        if finish == .matte, pattern == .rich {
            return ModeRecommendation(
                kind: .objectCapture,
                strength: .strong,
                rationale: String(localized: "Mat ve dokulu yüzey fotogrametrinin en iyi çalıştığı durum. Bu objede geometri detayı TrueDepth'ten belirgin şekilde yüksek olur."),
                warnings: warnings,
                tips: tips
            )
        }

        return ModeRecommendation(
            kind: .objectCapture,
            strength: finish == .glossy ? .qualified : .strong,
            rationale: String(localized: "Yüzeyde eşleşmeye yetecek kadar detay var; fotogrametri bu objede iyi sonuç verir."),
            warnings: warnings,
            tips: tips
        )
    }

}
