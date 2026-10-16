import RealityKit

/// Every capability is queried from the framework at runtime.
///
/// The tempting alternative — matching `utsname.machine` against a list of
/// model identifiers — breaks on every new device and on the simulator. Apple
/// exposes real predicates for all of this; use them.
///
/// `@MainActor` because `PhotogrammetrySession.isSupported` is main-actor isolated.
@MainActor
enum DeviceCapabilities {

    /// On-device photogrammetry. The turntable engine's hard requirement.
    static var supportsPhotogrammetry: Bool {
        PhotogrammetrySession.isSupported
    }
}
