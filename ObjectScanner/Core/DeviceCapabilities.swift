import AVFoundation
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

    static var cameraAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestCameraAccess() async -> Bool {
        if cameraAuthorization == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Only genuinely blocking conditions produce a warning. Anything softer is
    /// left to the pose diagnostics — a scary banner that fires on healthy
    /// hardware is worse than no banner at all.
    static var blockingHardwareWarning: String? {
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) == nil {
            return String(localized: "Rear wide camera not found. Scanning is not possible.")
        }
        if !supportsPhotogrammetry {
            return String(localized: "This device doesn't support on-device photogrammetry.")
        }
        return nil
    }
}
