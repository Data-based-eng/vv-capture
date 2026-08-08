import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Tara", systemImage: "cube.transparent") {
                NavigationStack { ScanSetupView() }
            }
            Tab("Kütüphane", systemImage: "square.stack.3d.up") {
                NavigationStack { LibraryView() }
            }
        }
    }
}

#Preview {
    RootView()
        .environment(ScanStorage())
        .preferredColorScheme(.dark)
}
