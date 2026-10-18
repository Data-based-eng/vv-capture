import SwiftUI
#if os(iOS)
import QuickLook
#else
import AppKit
import QuickLookUI
#endif

/// USDZ preview via Quick Look.
///
/// Quick Look is used rather than a hand-rolled RealityKit scene because it
/// already ships orbit/pinch gestures, AR placement, and correct lighting for
/// USDZ — none of which is the interesting part of this app.
#if os(iOS)
struct ModelPreviewView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
#else
/// macOS variant: QLPreviewView embedded via NSViewRepresentable.
struct ModelPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? URL) != url else { return }
        view.previewItem = url as NSURL
    }
}
#endif
