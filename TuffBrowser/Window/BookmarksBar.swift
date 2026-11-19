import SwiftUI
import UniformTypeIdentifiers

/// The row of bookmarks under the address bar in the horizontal layout, turned on with ⇧⌘B
/// (as in Chrome and Firefox). Pages open in the tab on screen (⌘-click or middle-click: a new
/// tab), folders open a list, and what doesn't fit goes behind » at the end. Bookmarks drag to
/// reorder or into a folder; tabs and links dragged here are bookmarked.
struct BookmarksBar: View {
    @Environment(BrowserState.self) private var state

    static let itemHeight: CGFloat = 24
    static let gap: CGFloat = 2
    static let maxTitleWidth: CGFloat = 150
    static let overflowWidth: CGFloat = 26
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    var body: some View {
        let items = state.bookmarksProfileID.map { BookmarkStore.shared.items(for: $0) } ?? []
        GeometryReader { geo in
            let widths = items.map(Self.width(of:))
            let shown = Self.fitting(widths, in: geo.size.width)
            HStack(spacing: Self.gap) {
                if items.isEmpty {
                    Text("Bookmark pages with ⇧⌘D, or drag a tab or link here.")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.42))
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
                ForEach(Array(items.prefix(shown).enumerated()), id: \.element.id) { index, bookmark in
                    BookmarkBarItem(bookmark: bookmark, index: index, width: widths[index])
                }
                // The rest of the bar takes drops at the end.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onDrop(of: [.url, .text], delegate: BookmarkDropDelegate(target: nil, index: items.count, state: state))
                if shown < items.count {
                    BookmarkOverflowButton(items: Array(items.dropFirst(shown)))
                }
            }
            .frame(height: geo.size.height)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Folder…") { Task { @MainActor in await state.addBookmarkFolder() } }
            Divider()
            Button("Hide Bookmarks Bar") { state.toggleBookmarksBar() }
        }
        .animation(Motion.snappy, value: items.map(\.id))
    }

    /// An item's width: its icon, and its title up to `maxTitleWidth`.
    static func width(of bookmark: Bookmark) -> CGFloat {
        let title = bookmark.isFolder ? bookmark.displayTitle : bookmark.title.trimmed
        guard !title.isEmpty else { return 28 }
        let text = (title as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return 8 + 16 + 6 + min(text, maxTitleWidth) + 9
    }

    /// How many items fit in `width`, leaving room for the » button when not all of them do.
    static func fitting(_ widths: [CGFloat], in width: CGFloat) -> Int {
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        guard total > width else { return widths.count }
        let room = width - overflowWidth - gap
        var used: CGFloat = 0
        for (index, item) in widths.enumerated() {
            used += item + (index > 0 ? gap : 0)
            if used > room { return index }
        }
        return widths.count
    }
}

/// A page (icon and title) or a folder on the bar.
private struct BookmarkBarItem: View {
    @Environment(BrowserState.self) private var state
    @Environment(\.accent) private var accent
    let bookmark: Bookmark
    let index: Int
    let width: CGFloat
    @State private var hovering = false
    @State private var showingFolder = false
    /// A tab, link or bookmark is over this folder and would go into it.
    @State private var targeted = false

    var body: some View {
        let title = bookmark.isFolder ? bookmark.displayTitle : bookmark.title.trimmed
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 6) {
            if let url = bookmark.url {
                BookmarkFavicon(url: url)
            } else {
                Image(systemName: showingFolder ? "folder.fill" : "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.primary.opacity(hovering || showingFolder ? 0.92 : 0.75))
        .padding(.leading, title.isEmpty ? 0 : 8)
        .padding(.trailing, title.isEmpty ? 0 : 9)
        .frame(width: width, height: BookmarksBar.itemHeight)
        .background(shape.fill(.primary.opacity(showingFolder ? 0.13 : (hovering ? 0.09 : 0))))
        .overlay(shape.strokeBorder(accent.opacity(targeted ? 0.85 : 0), lineWidth: 1.5))
        .contentShape(shape)
        .onTapGesture {
            if bookmark.isFolder {
                showingFolder.toggle()
            } else {
                let newTab = NSEvent.modifierFlags.contains(.command)
                state.open(bookmark, inNewTab: newTab, select: !newTab)
            }
        }
        .onMiddleClick {
            if bookmark.isFolder { state.openAll(in: bookmark) } else { state.open(bookmark, inNewTab: true, select: false) }
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: targeted)
        .help(bookmark.url.map { "\(bookmark.displayTitle)\n\($0.absoluteString)" } ?? bookmark.displayTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bookmark.isFolder ? "Folder \(bookmark.displayTitle)" : bookmark.displayTitle))
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $showingFolder, arrowEdge: .bottom) {
            BookmarkListMenu(items: bookmark.children, folder: bookmark) { showingFolder = false }
        }
        .contextMenu { BookmarkContextMenu(bookmark: bookmark, index: index) }
        .onDrag {
            state.draggingBookmarkID = bookmark.id
            if let url = bookmark.url { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: bookmark.displayTitle as NSString)
        }
        .onDrop(of: [.url, .text], delegate: BookmarkDropDelegate(target: bookmark, index: index, state: state, targeted: $targeted))
        .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
    }
}

/// » at the end of the bar: the bookmarks that didn't fit.
private struct BookmarkOverflowButton: View {
    let items: [Bookmark]
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "chevron.right.2")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.primary.opacity(hovering || showing ? 0.85 : 0.55))
                .frame(width: BookmarksBar.overflowWidth, height: BookmarksBar.itemHeight)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(hovering || showing ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("More Bookmarks")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            BookmarkListMenu(items: items, folder: nil) { showing = false }
        }
    }
}

/// A folder's bookmarks (or the ones behind ») as a list; folders inside open in place, with a
/// row at the top to go back.
private struct BookmarkListMenu: View {
    @Environment(BrowserState.self) private var state
    let items: [Bookmark]
    /// The folder being listed, for Open All; nil for the » list.
    let folder: Bookmark?
    let close: () -> Void
    @State private var path: [Bookmark] = []

    var body: some View {
        let current = path.last ?? folder
        let list = path.last?.children ?? items
        StripPopoverMenu(width: 280) {
            if let inner = path.last {
                StripMenuRow(title: inner.displayTitle, symbol: "chevron.left") {
                    path.removeLast()
                }
                StripMenuDivider()
            }
            ForEach(list) { item in
                if item.isFolder {
                    StripMenuRow(title: item.displayTitle, symbol: "folder", disclosure: true) {
                        path.append(item)
                    }
                    .contextMenu { rowMenu(item) }
                } else {
                    let icon = item.url.flatMap { FaviconStore.shared.cachedIcon(for: $0) }
                    StripMenuRow(title: item.displayTitle, symbol: icon == nil ? "globe" : nil, image: icon) {
                        let newTab = NSEvent.modifierFlags.contains(.command)
                        closeThen { state.open(item, inNewTab: newTab, select: !newTab) }
                    }
                    .help(item.url?.absoluteString ?? "")
                    .contextMenu { rowMenu(item) }
                }
            }
            if list.isEmpty {
                StripMenuRow(title: "Empty folder", symbol: "folder", disabled: true) {}
            }
            if let current, current.pages.count > 1 {
                StripMenuDivider()
                StripMenuRow(title: "Open All in New Tabs", symbol: "plus.square.on.square") {
                    closeThen { state.openAll(in: current) }
                }
            }
        }
    }

    @ViewBuilder private func rowMenu(_ item: Bookmark) -> some View {
        if item.isFolder {
            Button("Open All in New Tabs") { closeThen { state.openAll(in: item) } }
                .disabled(item.pages.isEmpty)
            Divider()
            Button("Rename…") { closeThen { Task { @MainActor in await state.edit(item) } } }
            Button("Delete Folder") { closeThen { Task { @MainActor in await state.delete(item) } } }
        } else {
            Button("Open in New Tab") { closeThen { state.open(item, inNewTab: true) } }
            Divider()
            Button("Edit…") { closeThen { Task { @MainActor in await state.edit(item) } } }
            Button("Copy Link") { copy(item.url) }
            Button("Delete") { closeThen { Task { @MainActor in await state.delete(item) } } }
        }
    }

    private func closeThen(_ action: @escaping () -> Void) {
        close()
        DispatchQueue.main.async(execute: action)
    }
}

/// The right-click menu of a bookmark or folder on the bar.
private struct BookmarkContextMenu: View {
    @Environment(BrowserState.self) private var state
    let bookmark: Bookmark
    let index: Int

    var body: some View {
        if bookmark.isFolder {
            Button("Open All in New Tabs") { state.openAll(in: bookmark) }
                .disabled(bookmark.pages.isEmpty)
            Divider()
            Button("Rename…") { Task { @MainActor in await state.edit(bookmark) } }
            Button("Delete Folder") { Task { @MainActor in await state.delete(bookmark) } }
        } else {
            Button("Open in New Tab") { state.open(bookmark, inNewTab: true) }
            if let url = bookmark.url, state.selectedTab != nil {
                Button("Open in Split View") { state.open(url: url, mode: .splitTab) }
            }
            Divider()
            Button("Edit…") { Task { @MainActor in await state.edit(bookmark) } }
            Button("Copy Link") { copy(bookmark.url) }
            Button("Delete") { Task { @MainActor in await state.delete(bookmark) } }
        }
        Divider()
        Button("New Folder…") { Task { @MainActor in await state.addBookmarkFolder(at: index + 1) } }
        Button("Hide Bookmarks Bar") { state.toggleBookmarksBar() }
    }
}

private func copy(_ url: URL?) {
    guard let url else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}

/// A bookmarked site's icon: the cached one, else fetched once from the site.
private struct BookmarkFavicon: View {
    let url: URL
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.55))
            }
        }
        .frame(width: 16, height: 16)
        .task(id: url) {
            if let cached = FaviconStore.shared.cachedIcon(for: url) {
                icon = cached
                return
            }
            guard let host = url.host, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            FaviconStore.shared.icon(forHost: host) { image in
                DispatchQueue.main.async { if let image { icon = image } }
            }
        }
    }
}

/// Drops on the bar: a bookmark dragged along it moves as it goes (or into a folder when let
/// go over one), and a tab or a link is bookmarked where it lands.
private struct BookmarkDropDelegate: DropDelegate {
    /// nil for the empty end of the bar.
    let target: Bookmark?
    /// The target's place on the bar.
    let index: Int
    let state: BrowserState
    var targeted: Binding<Bool>?

    private var folder: UUID? { target?.isFolder == true ? target?.id : nil }

    func validateDrop(info: DropInfo) -> Bool {
        state.draggingBookmarkID != nil || state.draggingTab != nil || info.hasItemsConforming(to: [.url])
    }

    func dropEntered(info: DropInfo) {
        if let dragged = state.draggingBookmarkID, state.draggingTab == nil {
            guard dragged != target?.id else { return }
            if folder != nil {
                targeted?.wrappedValue = true
            } else if let profile = state.bookmarksProfileID {
                withAnimation(Motion.snappy) {
                    BookmarkStore.shared.move(dragged, into: nil, at: target == nil ? nil : index, profile: profile)
                }
            }
        } else if folder != nil {
            targeted?.wrappedValue = true
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: state.draggingBookmarkID != nil && state.draggingTab == nil ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        targeted?.wrappedValue = false
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted?.wrappedValue = false
        guard let profile = state.bookmarksProfileID else { return false }
        // Into a folder at its end; on a page, in its place; on the empty end, last.
        let at = folder != nil || target == nil ? nil : index
        if let dragged = state.draggingBookmarkID, state.draggingTab == nil {
            if let folder, folder != dragged {
                withAnimation(Motion.snappy) { BookmarkStore.shared.move(dragged, into: folder, at: nil, profile: profile) }
            }
            return endSidebarDrag(state)
        }
        if let tab = state.draggingTab {
            state.bookmark(tab, into: folder, at: at)
            return endSidebarDrag(state)
        }
        // A link dragged from a page or another app.
        guard let provider = info.itemProviders(for: [.url]).first else { return false }
        let into = folder
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                guard Bookmark.canSave(url) else { return }
                let title = state.allTabs.first { $0.url == url }?.displayTitle ?? url.displayHost
                withAnimation(Motion.snappy) {
                    _ = BookmarkStore.shared.add(url: url, title: title, profile: profile, into: into, at: at)
                }
            }
        }
        return true
    }
}
