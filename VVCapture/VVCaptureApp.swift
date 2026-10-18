import SwiftUI

@main
struct VVCaptureApp: App {
    /// One store for the whole app: it owns the on-disk scan library and hands out
    /// per-scan workspaces to the capture engine.
    @State private var storage = ScanStorage()

    init() {
        // The brand's single typeface. Registered with the process because the
        // generated Info.plist route (INFOPLIST_KEY_UIAppFonts) silently drops
        // array values — verified 2026-10-17.
        BrandFont.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(storage)
        }
    }
}
