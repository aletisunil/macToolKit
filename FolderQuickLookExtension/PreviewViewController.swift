import AppKit
@preconcurrency import QuickLookUI
import SwiftUI

/// Finder owns the Quick Look window and gives this extension the folder URL
/// being previewed. No global key tap or Finder Apple Event is involved.
@MainActor
final class PreviewViewController: NSViewController, @MainActor QLPreviewingController {
    private let scanner = FolderScanner()
    private var model: PeekViewModel?
    private var hostingController: NSHostingController<AnyView>?

    override func loadView() {
        let hostingController = NSHostingController(
            rootView: AnyView(Color(nsColor: .windowBackgroundColor)))
        addChild(hostingController)
        self.hostingController = hostingController

        // The hosting view is pinned inside a plain container instead of being
        // the root view itself: Quick Look resizes the root when the panel is
        // dragged or taken full screen, and the constraints carry that through
        // to SwiftUI.
        let container = NSView(frame: NSRect(origin: .zero, size: preferredPreviewSize))
        let hosted = hostingController.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        present(folder: url.standardizedFileURL)
        // Assigning a SwiftUI root schedules its first render for the next
        // main-run-loop turn. Tell Quick Look the preview is ready only after
        // that pass, otherwise the host snapshots the placeholder view.
        DispatchQueue.main.async { [weak self] in
            self?.view.layoutSubtreeIfNeeded()
            handler(nil)
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        model?.cancel()
    }

    private func present(folder url: URL) {
        model?.cancel()

        let settings = FolderPeekSettings.load()
        let model = PeekViewModel(root: url, scanner: scanner, settings: settings)
        model.onOpenItem = { itemURL in
            NSWorkspace.shared.open(itemURL)
        }

        self.model = model
        hostingController?.rootView = AnyView(PeekView(model: model))
        preferredContentSize = preferredPreviewSize
        model.load()
    }

    private var preferredPreviewSize: NSSize {
        NSSize(width: 810, height: 640)
    }
}
