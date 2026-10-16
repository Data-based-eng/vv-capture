import SwiftUI

@main
struct VVCaptureApp: App {
    /// One store for the whole app: it owns the on-disk scan library and hands out
    /// per-scan workspaces to the capture engine.
    @State private var storage = ScanStorage()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(storage)
                .preferredColorScheme(.dark)
        }
    }
}
