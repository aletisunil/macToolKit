import AppKit
@preconcurrency import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Finder owns the Quick Look window and gives this extension the URL being
/// previewed. No global key tap or Finder Apple Event is involved.
@MainActor
final class PreviewViewController: NSViewController, @MainActor QLPreviewingController {
    private var model: PeekViewModel?
    private var hostingController: NSHostingController<AnyView>?

    /// Declining a preview hands the item back to Quick Look, which falls
    /// through to whatever it would have shown without this extension.
    private enum PreviewRefusal: Error {
        case notPreviewable
    }

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
        let url = url.standardizedFileURL
        guard let provider = provider(for: url) else {
            handler(PreviewRefusal.notPreviewable)
            return
        }
        presentPeek(url, with: provider)
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

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let model,
              let screen = view.window?.screen ?? NSScreen.main else { return }
        let fullScreen = PeekChrome.isFullScreen(
            contentHeight: view.bounds.height,
            visibleFrameHeight: screen.visibleFrame.height)
        if model.isFullScreen != fullScreen { model.isFullScreen = fullScreen }
    }

    // MARK: Routing

    /// Picks how to read the item, or nil when Quick Look should keep its own
    /// preview: the Trash, and anything that is neither a folder nor a zip.
    private func provider(for url: URL) -> PeekContentProvider? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        let settings = PeekSettings.load()

        switch PeekRouting.target(
            for: url,
            isDirectory: values?.isDirectory ?? false,
            contentType: values?.contentType) {
        case .folder:
            return FolderContentProvider(
                root: url, showHidden: settings.showHiddenFiles)
        case .archive:
            // A truncated or otherwise unreadable archive throws here;
            // refusing keeps the system's plain icon preview rather than
            // showing an empty tree.
            return try? ArchiveContentProvider(
                archive: url, showHidden: settings.showHiddenFiles)
        case .refuse:
            return nil
        }
    }

    private func presentPeek(_ url: URL, with provider: PeekContentProvider) {
        model?.cancel()

        let model = PeekViewModel(
            root: url, provider: provider, settings: PeekSettings.load())
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
