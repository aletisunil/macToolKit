import AppKit
import ScreenCaptureKit

/// On-demand window thumbnails via ScreenCaptureKit, keyed by CGWindowID.
///
/// Capture happens only while the switcher is being shown — never
/// continuously — and results are cached so the next invocation renders
/// instantly with slightly stale images while fresh ones stream in.
/// Without Screen Recording permission this does nothing and the switcher
/// falls back to app-icon tiles.
@MainActor
final class ThumbnailService: ObservableObject {
    @Published private(set) var thumbnails: [CGWindowID: CGImage] = [:]

    /// Longest edge of a captured thumbnail, in pixels.
    private nonisolated static let maxPixels: CGFloat = 600

    private var generation = 0

    /// Captures fresh thumbnails for the visible (non-minimized) windows.
    func refresh(for windows: [WindowInfo]) {
        guard Permissions.screenRecordingGranted else { return }
        generation += 1
        let current = generation
        let targets = windows.filter { !$0.isMinimized }.map(\.id)

        // Drop images for windows that have since closed. Without this the
        // cache only ever grows: every window opened during the session keeps
        // a full-size CGImage alive for as long as the app runs.
        let live = Set(windows.map(\.id))
        thumbnails = thumbnails.filter { live.contains($0.key) }

        Task {
            // onScreenWindowsOnly: false so other-space windows can be
            // captured too (SCK can screenshot them without switching).
            guard let content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: false)
            else { return }
            let scWindows = Dictionary(
                uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })

            // Sequential awaits: each capture is tens of milliseconds and the
            // tiles fill in progressively; the main thread is never blocked.
            for id in targets {
                guard generation == current else { return }
                guard let window = scWindows[id] else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let scale = min(1, Self.maxPixels / max(window.frame.width,
                                                        window.frame.height, 1))
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config),
                   generation == current {
                    thumbnails[id] = image
                }
            }
        }
    }

    func clearCache() {
        thumbnails = [:]
    }
}
