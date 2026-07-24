import SwiftUI

/// The switcher overlay: a material card of window tiles in one of three
/// styles — thumbnails (auto-sized by window aspect ratio), a dock-like row
/// of app icons, or a vertical titles list. Selection is driven by the event
/// tap through the controller; hover moves it, click commits. Hovering a
/// thumbnail also reveals close/minimize/fullscreen buttons.
struct SwitcherView: View {
    @ObservedObject var controller: WindowSwitcherController
    @ObservedObject var thumbnails: ThumbnailService

    private var scale: CGFloat { controller.thumbnailSize.scale }
    private var maxRowWidth: CGFloat { 1040 * max(1, scale) }

    var body: some View {
        VStack(spacing: 10) {
            switch controller.activeStyle {
            case .thumbnails: thumbnailGrid
            case .appIcons: iconRow
            case .titles: titleList
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        )
        .padding(2)
    }

    // MARK: Thumbnails style

    private var thumbnailGrid: some View {
        FlowLayout(spacing: 10, maxRowWidth: maxRowWidth) {
            ForEach(Array(controller.visibleWindows.enumerated()),
                    id: \.element.id) { index, window in
                ThumbnailTile(window: window,
                              thumbnail: thumbnails.thumbnails[window.id],
                              selected: index == controller.selection,
                              scale: scale,
                              alignment: controller.alignment,
                              controller: controller)
                    .onHover { hovering in
                        if hovering, controller.hoverCanSelect() {
                            controller.selection = index
                        }
                    }
                    .onTapGesture {
                        controller.selection = index
                        controller.commit()
                    }
            }
        }
        .frame(maxWidth: maxRowWidth)
    }

    // MARK: App icons style

    private var iconRow: some View {
        VStack(spacing: 8) {
            FlowLayout(spacing: 8, maxRowWidth: maxRowWidth) {
                ForEach(Array(controller.visibleWindows.enumerated()),
                        id: \.element.id) { index, window in
                    IconTile2(window: window,
                              selected: index == controller.selection,
                              scale: scale)
                        .onHover { hovering in
                            if hovering, controller.hoverCanSelect() {
                                controller.selection = index
                            }
                        }
                        .onTapGesture {
                            controller.selection = index
                            controller.commit()
                        }
                }
            }
            if let selected = selectedWindow {
                Text(selected.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)
            }
        }
    }

    // MARK: Titles style

    private var titleList: some View {
        VStack(spacing: 2) {
            ForEach(Array(controller.visibleWindows.enumerated()),
                    id: \.element.id) { index, window in
                TitleRow(window: window,
                         selected: index == controller.selection,
                         alignment: controller.alignment,
                         scale: scale)
                    .onHover { hovering in
                        if hovering, controller.hoverCanSelect() {
                            controller.selection = index
                        }
                    }
                    .onTapGesture {
                        controller.selection = index
                        controller.commit()
                    }
            }
        }
        .frame(width: 460 * scale)
    }

    private var selectedWindow: WindowInfo? {
        let windows = controller.visibleWindows
        return (0..<windows.count).contains(controller.selection)
            ? windows[controller.selection] : nil
    }
}

// MARK: - Badges

private struct WindowBadges: View {
    let window: WindowInfo

    var body: some View {
        HStack(spacing: 3) {
            if window.isMinimized {
                badge(icon: "arrow.down.right.square.fill")
            }
            if window.isHidden {
                badge(icon: "eye.slash.fill")
            }
            if let space = window.spaceNumber {
                Text("\(space)")
                    .font(.caption2.monospaced().weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
    }

    private func badge(icon: String) -> some View {
        Image(systemName: icon)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Thumbnail tile

private struct ThumbnailTile: View {
    let window: WindowInfo
    let thumbnail: CGImage?
    let selected: Bool
    let scale: CGFloat
    let alignment: SwitcherAlignment
    let controller: WindowSwitcherController

    @State private var hovering = false

    private var thumbHeight: CGFloat { 124 * scale }
    /// Auto-sizing: tile width follows the window's aspect ratio.
    private var thumbWidth: CGFloat {
        let aspect = window.frame.height > 0
            ? window.frame.width / window.frame.height : 16 / 10
        return (thumbHeight * min(max(aspect, 0.6), 2.2)).rounded()
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                preview
                    .frame(width: thumbWidth, height: thumbHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 34 * scale, height: 34 * scale)
                        .offset(x: 4, y: 6)
                }
            }
            .overlay(alignment: .topLeading) {
                if hovering && window.axWindow != nil {
                    WindowControls(window: window, controller: controller)
                        .padding(4)
                }
            }

            HStack(spacing: 4) {
                WindowBadges(window: window)
                Text(window.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(width: thumbWidth,
                   alignment: alignment == .leading ? .leading : .center)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(window.accessibilityDescription))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail, !window.isMinimized {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let icon = window.icon {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.4))
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64 * scale, height: 64 * scale)
            }
        } else {
            Rectangle().fill(.quaternary.opacity(0.4))
        }
    }
}

/// Close / minimize / fullscreen buttons revealed on hover, macOS-traffic-
/// light order. Only for windows with an AX handle (current space).
private struct WindowControls: View {
    let window: WindowInfo
    let controller: WindowSwitcherController

    var body: some View {
        HStack(spacing: 5) {
            control(icon: "xmark", help: "Close") {
                controller.perform(.close, on: window)
            }
            control(icon: "minus", help: "Minimize") {
                controller.perform(.minimize, on: window)
            }
            control(icon: "arrow.up.left.and.arrow.down.right", help: "Full Screen") {
                window.toggleFullscreen()
            }
        }
        .padding(4)
        .background(Capsule().fill(.regularMaterial))
    }

    private func control(icon: String, help: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - App icon tile

private struct IconTile2: View {
    let window: WindowInfo
    let selected: Bool
    let scale: CGFloat

    private var side: CGFloat { 64 * scale }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: side, height: side)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .frame(width: side, height: side)
                }
                WindowBadges(window: window)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(window.accessibilityDescription))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Title row

private struct TitleRow: View {
    let window: WindowInfo
    let selected: Bool
    let alignment: SwitcherAlignment
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20 * scale, height: 20 * scale)
            }
            Text(window.displayTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if alignment == .leading { Spacer(minLength: 8) }
            WindowBadges(window: window)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity,
               alignment: alignment == .leading ? .leading : .center)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(window.accessibilityDescription))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Flow layout

/// Left-to-right wrap layout for auto-sized tiles (SwiftUI's grids need
/// fixed columns; thumbnail widths vary with window aspect ratio).
private struct FlowLayout: Layout {
    let spacing: CGFloat
    let maxRowWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        arrange(subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = arrangement.frames[index]
            // Center each row within the widest row.
            let rowWidth = arrangement.rowWidths[arrangement.rowOf[index]]
            let inset = (arrangement.size.width - rowWidth) / 2
            subview.place(
                at: CGPoint(x: bounds.minX + inset + frame.minX,
                            y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private struct Arrangement {
        var frames: [CGRect] = []
        var rowOf: [Int] = []
        var rowWidths: [CGFloat] = []
        var size: CGSize = .zero
    }

    private func arrange(subviews: Subviews) -> Arrangement {
        var result = Arrangement()
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var row = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxRowWidth {
                result.rowWidths.append(x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
                row += 1
            }
            result.frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            result.rowOf.append(row)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        result.rowWidths.append(x > 0 ? x - spacing : 0)
        result.size = CGSize(width: result.rowWidths.max() ?? 0,
                             height: y + rowHeight)
        return result
    }
}

private extension WindowInfo {
    var accessibilityDescription: String {
        var parts = [appName]
        if !title.isEmpty { parts.append(title) }
        if isMinimized { parts.append("minimized") }
        if isHidden { parts.append("hidden") }
        if let spaceNumber { parts.append("space \(spaceNumber)") }
        return parts.joined(separator: ", ")
    }
}
