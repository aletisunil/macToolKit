import AppKit
import SwiftUI

/// Drives one peek panel: lazy tree of the folder's contents plus the
/// header's deep size/count pass. Recreated for every peek, so all state is
/// per-folder.
@MainActor
final class PeekViewModel: ObservableObject {
    let rootURL: URL
    let settings: FolderPeekSettings

    /// Flattened visible tree (expanded nodes contribute their children).
    @Published private(set) var rows: [PeekNode] = []
    @Published private(set) var loaded = false
    @Published private(set) var topLevelCount = 0
    @Published private(set) var topLevelCountIsLowerBound = false
    @Published private(set) var deepBytes: Int64?
    @Published private(set) var folderBytes: [URL: Int64] = [:]
    @Published private(set) var calculating = true
    @Published private(set) var sort = PeekSort()
    @Published var selectedID: URL?

    var onOpenItem: ((URL) -> Void)?

    private let scanner: FolderScanner
    private var topNodes: [PeekNode] = []
    private var loadTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private static let expandedTreeCap = 4_000
    private static let preloadDirectoryCap = 256

    private struct PreloadBudget {
        var rows: Int
        var directories: Int
    }

    init(root: URL, scanner: FolderScanner, settings: FolderPeekSettings) {
        self.rootURL = root
        self.scanner = scanner
        self.settings = settings
    }

    var rootName: String { rootURL.lastPathComponent }

    var rootIcon: NSImage { NSWorkspace.shared.icon(forFile: rootURL.path) }

    var subtitle: String {
        var size = PeekFormat.size(deepBytes ?? 0)
        if calculating { size += "…" }
        let items: String
        if topLevelCountIsLowerBound {
            items = "\(topLevelCount)+ items"
        } else {
            items = topLevelCount == 1 ? "1 item" : "\(topLevelCount) items"
        }
        return "\(size) · \(items)"
    }

    /// Ancestor chain for the breadcrumb bar, ending at the peeked folder.
    var breadcrumb: [String] {
        var crumbs: [String] = []
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        var url = rootURL.standardizedFileURL
        while true {
            crumbs.insert(url.lastPathComponent, at: 0)
            if url == home { break }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path, parent.path != "/" else { break }
            url = parent
        }
        return Array(crumbs.suffix(4))
    }

    func displayedSize(for node: PeekNode) -> Int64? {
        if node.item.isDirectory {
            return folderBytes[node.item.url.standardizedFileURL]
                ?? (calculating ? nil : 0)
        }
        return node.item.size
    }

    // MARK: Loading

    func load() {
        loadTask?.cancel()
        let scanner = self.scanner
        let url = rootURL
        loadTask = Task {
            let listing = await scanner.list(
                rootURL, showHidden: settings.showHiddenFiles)
            guard !Task.isCancelled else { return }
            topLevelCount = listing.items.count
            topLevelCountIsLowerBound = listing.hasMoreItems
            topNodes = Self.nodes(for: listing, depth: 0)
            sortLevel(&topNodes)
            loaded = true
            flatten()

            let remainingRows = max(0, Self.expandedTreeCap - topNodes.count)
            if settings.depthLevel > 1, remainingRows > 0 {
                _ = await preload(
                    topNodes,
                    currentDepth: 1,
                    budget: PreloadBudget(
                        rows: remainingRows,
                        directories: Self.preloadDirectoryCap))
            }
        }

        statsTask = Task.detached(priority: .utility) { [weak self] in
            // Immutable copy: the weak binding itself is a var and can't be
            // captured by the inner Sendable closures.
            let model = self
            let stats = scanner.deepStats(of: url) { progress in
                Task { @MainActor in
                    model?.deepBytes = progress.bytes
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                model?.deepBytes = stats.bytes
                model?.folderBytes = stats.folderBytes
                model?.calculating = stats.partial
                if model?.sort.column == .size {
                    model?.sortTreeAndFlatten()
                }
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        statsTask?.cancel()
        statsTask = nil
    }

    private static func nodes(for listing: FolderScanner.Listing, depth: Int) -> [PeekNode] {
        var nodes = listing.items.map { PeekNode(item: $0, depth: depth) }
        if listing.hasMoreItems, let last = listing.items.last {
            // Synthetic trailing row; the URL only has to be a unique id.
            let marker = PeekItem(
                url: last.url.appendingPathComponent(".macToolKit-truncated"),
                name: "", isDirectory: false, isPackage: false,
                size: nil, modified: nil, kind: "")
            nodes.append(PeekNode(
                item: marker,
                depth: depth,
                isTruncationMarker: true))
        }
        return nodes
    }

    // MARK: Tree operations

    func toggle(_ node: PeekNode) {
        guard node.item.isDirectory else { return }
        if node.isExpanded {
            node.isExpanded = false
            flatten()
            return
        }
        if node.children != nil {
            node.isExpanded = true
            flatten()
            return
        }
        guard !node.isLoading else { return }
        node.isLoading = true
        flatten()
        Task {
            let listing = await scanner.list(
                node.item.url, showHidden: settings.showHiddenFiles)
            var children = Self.nodes(for: listing, depth: node.depth + 1)
            sortLevel(&children)
            node.children = children
            node.isLoading = false
            node.isExpanded = true
            flatten()
        }
    }

    /// Preloads and expands the configured number of nested levels. Row and
    /// directory-scan budgets keep depth 3 responsive for broad or mostly
    /// empty directory hierarchies.
    private func preload(
        _ nodes: [PeekNode],
        currentDepth: Int,
        budget: PreloadBudget
    ) async -> PreloadBudget {
        guard !Task.isCancelled,
              currentDepth < settings.depthLevel,
              budget.rows > 0,
              budget.directories > 0 else {
            return budget
        }

        var budget = budget
        for node in nodes where node.item.isDirectory
            && budget.rows > 0
            && budget.directories > 0 {
            guard !Task.isCancelled else { return budget }
            budget.directories -= 1
            node.isLoading = true
            flatten()
            let listing = await scanner.list(
                node.item.url, showHidden: settings.showHiddenFiles)
            guard !Task.isCancelled else { return budget }
            var children = Self.nodes(for: listing, depth: node.depth + 1)
            if children.count > budget.rows {
                children = Array(children.prefix(budget.rows))
            }
            sortLevel(&children)
            node.children = children
            node.isExpanded = true
            node.isLoading = false
            budget.rows -= children.count
            flatten()
            budget = await preload(
                children,
                currentDepth: currentDepth + 1,
                budget: budget)
        }
        return budget
    }

    func setSort(_ column: PeekSort.Column) {
        if sort.column == column {
            sort.ascending.toggle()
        } else {
            sort = PeekSort(column: column, ascending: true)
        }
        sortTree(&topNodes)
        flatten()
    }

    private func sortLevel(_ nodes: inout [PeekNode]) {
        // The synthetic "… more" row stays pinned at the end.
        nodes.sort {
            switch ($0.isTruncationMarker, $1.isTruncationMarker) {
            case (false, false):
                if sort.column == .size {
                    let first = displayedSize(for: $0) ?? -1
                    let second = displayedSize(for: $1) ?? -1
                    return sort.ascending ? first < second : first > second
                }
                return sort.areSorted($0.item, $1.item)
            case (false, true): return true
            default: return false
            }
        }
    }

    private func sortTree(_ nodes: inout [PeekNode]) {
        sortLevel(&nodes)
        for node in nodes where node.children != nil {
            sortTree(&node.children!)
        }
    }

    private func sortTreeAndFlatten() {
        sortTree(&topNodes)
        flatten()
    }

    private func flatten() {
        var result: [PeekNode] = []
        func walk(_ nodes: [PeekNode]) {
            for node in nodes {
                result.append(node)
                if node.isExpanded, let children = node.children {
                    walk(children)
                }
            }
        }
        walk(topNodes)
        rows = result
    }

    // MARK: Keyboard

    func moveSelection(_ delta: Int) {
        let selectable = rows.filter { !$0.isTruncationMarker }
        guard !selectable.isEmpty else { return }
        guard let current = selectable.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = (delta >= 0 ? selectable.first : selectable.last)?.id
            return
        }
        let next = max(0, min(selectable.count - 1, current + delta))
        selectedID = selectable[next].id
    }

    func expandSelected(_ expand: Bool) {
        guard let node = rows.first(where: { $0.id == selectedID }) else { return }
        if node.isExpanded != expand { toggle(node) }
    }

    func openSelected() {
        guard let node = rows.first(where: { $0.id == selectedID }),
              !node.isTruncationMarker else { return }
        onOpenItem?(node.item.url)
    }
}

// MARK: - View

struct PeekView: View {
    @ObservedObject var model: PeekViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            contents
            if model.settings.showPathBar {
                breadcrumbBar
            }
        }
        // Quick Look asks the extension for this exact canvas. An explicit
        // size also prevents the remote SwiftUI host from resolving flexible
        // infinity constraints to an empty placeholder.
        .frame(width: 810, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: model.rootIcon)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.rootName)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        // Quick Look supplies its own close/open/share controls across the
        // top edge, so keep the folder identity below that native chrome.
        .padding(.horizontal, 16)
        .padding(.top, 34)
        .frame(height: 96)
    }

    private var contents: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 6)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            columnDivider
            sortButton("Name", column: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            columnDivider
            sortButton("Date Modified", column: .modified)
                .frame(width: 160, alignment: .leading)
            columnDivider
            sortButton("Size", column: .size)
                .frame(width: 106, alignment: .trailing)
            columnDivider
            sortButton("Kind", column: .kind)
                .frame(width: 160, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.black.opacity(0.06))
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 16)
    }

    private func sortButton(_ title: String, column: PeekSort.Column) -> some View {
        Button {
            model.setSort(column)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 3)
                if model.sort.column == column {
                    Image(systemName: model.sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, node in
                        PeekRowView(
                            model: model,
                            node: node,
                            striped: index % 2 == 1)
                            .id(node.id)
                    }
                }
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .overlay {
                if !model.loaded {
                    ProgressView()
                        .controlSize(.small)
                } else if model.rows.isEmpty {
                    Text("This folder is empty")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            let crumbs = model.breadcrumb
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                let isCurrent = index == crumbs.count - 1
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                    Text(crumb)
                        .font(.caption)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }
}

private struct PeekRowView: View {
    @ObservedObject var model: PeekViewModel
    let node: PeekNode
    let striped: Bool

    var body: some View {
        if node.isTruncationMarker {
            Text("… More items not shown")
                .font(.callout.italic())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(16 + node.depth * 16 + 22))
                .frame(height: 32)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer().frame(width: CGFloat(node.depth) * 16)
                disclosure
                Image(nsImage: node.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: model.settings.iconSize.listPoints,
                        height: model.settings.iconSize.listPoints)
                Text(node.item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(PeekFormat.modified(node.item.modified))
                .padding(.horizontal, 8)
                .frame(width: 160, alignment: .leading)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(PeekFormat.size(model.displayedSize(for: node)))
                .padding(.horizontal, 8)
                .frame(width: 106, alignment: .trailing)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(node.item.kind)
                .padding(.horizontal, 8)
                .frame(width: 160, alignment: .leading)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .frame(height: max(32, model.settings.iconSize.listPoints + 10))
        .contentShape(Rectangle())
        .background(background)
        .onTapGesture(count: 2) {
            model.onOpenItem?(node.item.url)
        }
        .onTapGesture {
            model.selectedID = node.id
        }
    }

    @ViewBuilder private var disclosure: some View {
        if node.item.isDirectory {
            Button {
                model.toggle(node)
            } label: {
                if node.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 18)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                        .frame(width: 18)
                }
            }
            .buttonStyle(.plain)
        } else {
            Spacer().frame(width: 18)
        }
    }

    private var background: some View {
        Group {
            if model.selectedID == node.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            } else if striped {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            } else {
                Color.clear
            }
        }
        .padding(.horizontal, 10)
    }
}
