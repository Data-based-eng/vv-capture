import AVFoundation
import SwiftUI

/// Camera authorization helper.
///
/// C1 fix: nothing in the app ever requested camera access — on a real phone
/// the first launch showed a black preview and every capture tap silently
/// no-op'd. Gate session creation on `ensureVideoAccess()` before touching
/// `AVCaptureSession`; route a `false` result into the denial UI.
///
/// Contract with the engine agents: engines call
/// `guard await CameraPermission.ensureVideoAccess() else { ... }` at the top
/// of `start()`. `RootView` also gates up front so a denied user stays on the
/// mode picker with a Settings deep-link instead of bouncing through a flow
/// that can't start.
enum CameraPermission {
    /// Returns `true` when video capture may proceed.
    ///
    /// Requests `.video` access if the status is `.notDetermined`, using the
    /// async `requestAccess` variant. The system prompt resolves OFF the main
    /// thread, so callers must hop back to `MainActor` before touching UI.
    static func ensureVideoAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// User-facing copy for the denial path. Shown next to an "Open Settings"
    /// button that deep-links to the app's Settings page.
    static var denialMessage: String {
        String(
            localized: "Camera access is needed to 3D-scan products for VisionVend onboarding. Open Settings and allow camera access to continue.",
            comment: "Explains that camera permission was denied and how to fix it"
        )
    }
}
