import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var model: ReaderModel
    @EnvironmentObject private var library: Library
    @AppStorage(Keys.theme) private var themeName = Theme.paper.rawValue
    @State private var columns = NavigationSplitViewVisibility.doubleColumn
    @State private var showAppearance = false

    private var theme: Theme { Theme(rawValue: themeName) ?? .paper }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 420)
        } detail: {
            ZStack {
                ThemeBackground(theme: theme).ignoresSafeArea()
                BookPageView(role: .window)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .colorSchemeOverride(theme.colorScheme)
            .navigationTitle(model.book?.title ?? "Folio")
            .navigationSubtitle(model.book?.author ?? "")
            .toolbar { toolbarContent }
        }
        .onChange(of: model.searchFocusToken) { _, _ in
            if columns == .detailOnly { columns = .doubleColumn }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.closeBook() } label: { Label("Library", systemImage: "books.vertical") }
                .help("Back to the library")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.previousChapter() } label: { Label("Previous Chapter", systemImage: "chevron.left") }
                .disabled(!model.hasPrevious).help("Previous chapter (⌘[)")
            Button { model.nextChapter() } label: { Label("Next Chapter", systemImage: "chevron.right") }
                .disabled(!model.hasNext).help("Next chapter (⌘])")
            Button { model.toggleBookmark() } label: {
                Label("Bookmark", systemImage: model.isBookmarked ? "bookmark.fill" : "bookmark")
            }
            .help("Bookmark this spot (⌘D)")
            if model.canSwitchForm {
                Button { model.toggleOriginal() } label: {
                    Label(model.showsOriginal ? "Show as Text" : "Show Original Pages",
                          systemImage: model.showsOriginal ? "text.alignleft" : "doc.richtext")
                }
                .help(model.showsOriginal ? "Read the text reflowed in your own font and theme (⇧⌘P)" : "Read the PDF's original pages (⇧⌘P)")
            }
            Button { showAppearance.toggle() } label: { Label("Appearance", systemImage: "textformat.size") }
                .help("Font, size and theme")
                .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                    ReadingSettings(showFloat: false).frame(width: 380).padding(.vertical, 6)
                }
            Button { model.focusSearch() } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search this book (⌘F)")
            Button { model.toggleFloat() } label: { Label("Float", systemImage: "rectangle.on.rectangle.angled") }
                .help("Float the book in a borderless window (⇧⌘F)")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let book = model.book {
                Text(book.chapterTitles[min(model.chapter, book.chapterCount - 1)]).lineLimit(1)
                Spacer()
                if model.showsOriginal { Text("Page \(model.page + 1) of \(model.pageCount)").monospacedDigit() }
                Text(timeLeft).monospacedDigit()
                Text("\(Int((model.progress * 100).rounded()))%").monospacedDigit().frame(minWidth: 34, alignment: .trailing)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            GeometryReader { g in
                Rectangle().fill(theme.text.opacity(0.08)).frame(height: 2)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.text.opacity(0.35)).frame(width: g.size.width * CGFloat(model.progress), height: 2)
                    }
            }
            .frame(height: 2)
        }
        .background(ThemeBackground(theme: theme))
    }

    private var timeLeft: String {
        let m = model.minutesLeft
        if m < 1 { return "almost done" }
        if m < 60 { return "\(m) min left" }
        return "\(m / 60) h \(m % 60) min left"
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var model: ReaderModel

    var body: some View {
        VStack(spacing: 0) {
            if let book = model.book {
                HStack(alignment: .top, spacing: 12) {
                    EtherealCover(title: book.title, author: book.author, progress: model.progress,
                                  bookmarks: model.entry?.bookmarks.count ?? 0, animated: false)
                        .frame(width: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(white: 0.3))
                                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title).font(.system(size: 13, weight: .semibold, design: .serif)).lineLimit(3)
                        if !book.author.isEmpty {
                            Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text("\(Int((model.progress * 100).rounded()))% read").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            Picker("", selection: $model.sidebarTab) {
                ForEach(SidebarTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            switch model.sidebarTab {
            case .contents: ContentsList()
            case .search: SearchPanel()
            case .bookmarks: BookmarksList()
            }
        }
    }
}

struct ContentsList: View {
    @EnvironmentObject private var model: ReaderModel

    var body: some View {
        if let book = model.book {
            let current = currentTOCID(book)
            List {
                if book.toc.isEmpty {
                    ForEach(book.chapterTitles.indices, id: \.self) { i in
                        row(title: book.chapterTitles[i], depth: 0, current: i == model.chapter) { model.go(chapter: i) }
                    }
                } else {
                    ForEach(book.toc) { item in
                        row(title: item.title, depth: item.depth, current: item.id == current) {
                            model.go(chapter: item.chapter, block: item.block)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// The furthest TOC entry at or before the reading position is "current".
    private func currentTOCID(_ book: Book) -> Int? {
        let pos = (model.chapter, model.position)
        var best: Book.TOCItem?
        for item in book.toc where (item.chapter, item.block) <= pos {
            if let b = best, (b.chapter, b.block) > (item.chapter, item.block) { continue }
            best = item
        }
        return best?.id
    }

    private func row(title: String, depth: Int, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? Color.accentColor : (depth > 0 ? Color.secondary : Color.primary))
                .lineLimit(2)
                .padding(.leading, CGFloat(depth) * 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SearchPanel: View {
    @EnvironmentObject private var model: ReaderModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this book", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { model.nextHit() }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(HierarchicalShapeStyle.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

            HStack(spacing: 6) {
                Toggle("Aa", isOn: $model.options.matchCase).help("Match case and accents")
                Toggle("Whole words", isOn: $model.options.wholeWord)
                Toggle("All words", isOn: $model.options.allWords).help("Every word somewhere in the same paragraph, any order")
            }
            .toggleStyle(.button)
            .controlSize(.small)

            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.previousHit() } label: { Image(systemName: "chevron.up") }.help("Previous match (⇧⌘G)")
                Button { model.nextHit() } label: { Image(systemName: "chevron.down") }.help("Next match (⌘G)")
            }
            .buttonStyle(.borderless)
            .disabled(model.hits.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .onAppear { focused = true }
        .onChange(of: model.searchFocusToken) { _, _ in focused = true }
        .onChange(of: model.query) { _, _ in model.runSearch() }
        .onChange(of: model.options) { _, _ in model.runSearch(immediate: true) }

        List {
            if let book = model.book {
                ForEach(groupedHits, id: \.chapter) { group in
                    Section(book.chapterTitles[group.chapter]) {
                        ForEach(group.hits) { hit in
                            Button { model.select(hit) } label: {
                                Text(hit.snippet)
                                    .font(.system(size: 12))
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(hit == model.selectedHit ? Color.accentColor.opacity(0.18) : Color.clear)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var summary: String {
        if model.searching { return "Searching…" }
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty { return "Case, accents and curly quotes are ignored" }
        let n = model.hits.count
        if n == 0 { return "No matches" }
        let more = model.hitsTruncated ? "+" : ""
        if let s = model.selectedHit, let i = model.hits.firstIndex(of: s) { return "\(i + 1) of \(n)\(more)" }
        return "\(n)\(more) match\(n == 1 ? "" : "es")"
    }

    private struct Group { let chapter: Int; let hits: [SearchHit] }

    private var groupedHits: [Group] {
        var out: [Group] = []
        var current: [SearchHit] = []
        var ch = -1
        for h in model.hits {
            if h.chapter != ch {
                if !current.isEmpty { out.append(Group(chapter: ch, hits: current)) }
                current = []; ch = h.chapter
            }
            current.append(h)
        }
        if !current.isEmpty { out.append(Group(chapter: ch, hits: current)) }
        return out
    }
}

struct BookmarksList: View {
    @EnvironmentObject private var model: ReaderModel
    @EnvironmentObject private var library: Library

    var body: some View {
        let entry = library.entry(model.entryID)
        let marks = entry?.bookmarks ?? []
        VStack(spacing: 0) {
            if marks.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark",
                                       description: Text("Press ⌘D to bookmark the passage at the top of the page."))
            } else {
                List {
                    ForEach(marks) { mark in
                        Button { model.go(chapter: mark.chapter, block: mark.block) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.book?.chapterTitles[safe: mark.chapter] ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(mark.snippet).font(.system(size: 12)).lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Bookmark", role: .destructive) {
                                if let id = entry?.id { library.removeBookmark(id, mark.id) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
