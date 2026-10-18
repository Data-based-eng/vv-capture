import SwiftUI

/// Mac entry point.
///
/// The Mac app is the high-detail reconstruction companion: a folder of stills
/// or a video goes in, a medium/full/raw mesh comes out. There is no camera
/// capture here — the iPhone does that job.
@main
struct VVCaptureMacApp: App {
    /// One store for the whole app: it owns the on-disk scan library and hands
    /// out per-scan workspaces to the import engine.
    @State private var storage = ScanStorage()

    init() {
        // The brand's single typeface. Registered with the process because the
        // generated Info.plist route (INFOPLIST_KEY_UIAppFonts) silently drops
        // array values — verified 2026-10-17.
        BrandFont.register()
    }

    var body: some Scene {
        WindowGroup {
            MacImportView()
                .environment(storage)
        }
    }
}
