import SwiftUI

/// Single-purpose shell: turntable capture, then a fresh session.
/// One capture technology means no mode picker and no library tab —
/// finish a scan and the next one starts clean.
struct RootView: View {
    @State private var runID = UUID()

    var body: some View {
        TurntableFlowView {
            runID = UUID()
        }
        .id(runID)
    }
}

#Preview {
    RootView()
        .environment(ScanStorage())
        .preferredColorScheme(.dark)
}
