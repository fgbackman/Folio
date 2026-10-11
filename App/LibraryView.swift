import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var model: ReaderModel
    @State private var filter = ""
    @State private var shelfHits: [Library.ShelfHit] = []
    @State private var searchingShelf = false
    @State private var shelfQuery = ""
    @State private var dropTargeted = false
    @State private var tag: String?
    @AppStorage(Keys.pdfAsText) private var pdfAsText = false
    @AppStorage(Keys.shelfOrder) private var orderName = Library.Order.recent.rawValue

    private var order: Library.Order { Library.Order(rawValue: orderName) ?? .recent }

    private var shown: [LibraryEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        var all = library.sorted(by: order)
        if let tag { all = all.filter { $0.labels.contains(tag) } }
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q)
                || $0.labels.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if library.entries.isEmpty {
                    ContentUnavailableView {
                        Label("Your shelf is empty", systemImage: "books.vertical")
                    } description: {
                        Text("Drop EPUB, PDF, text, Markdown or HTML books here, or press ⌘O.")
                    } actions: {
                        Button("Open a Book…") { model.showImporter = true }.buttonStyle(.borderedProminent)
                        Button("Find Free Books…") { model.showDiscover = true }
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    let unfinished = library.atHand(4)
                    if !unfinished.isEmpty, tag == nil, filter.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContinueRow(entries: unfinished)
                    }
                    shelfControls
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 26, alignment: .top)],
                              alignment: .leading, spacing: 30) {
                        ForEach(shown) { BookCard(entry: $0) }
                    }
                }
                if !shelfQuery.isEmpty { shelfResults }
            }
            .padding(32)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { for url in urls { await library.add(url) } }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle("Library")
        .sheet(isPresented: $model.showDiscover) {
            DiscoverView().environmentObject(library).environmentObject(model)
        }
        .sheet(item: $model.coverPick) { CoverGallery(entry: $0).environmentObject(library) }
        .onChange(of: library.allTags) { _, tags in if let tag, !tags.contains(tag) { self.tag = nil } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { searchField }
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
            ToolbarItem(placement: .primaryAction) {
                Text("\(library.entries.count) book\(library.entries.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
            ToolbarItem(placement: .primaryAction) {
                Button { pdfAsText.toggle(); library.setAllOriginal(!pdfAsText) } label: {
                    Label(pdfAsText ? "PDFs Open as Text" : "PDFs Open as Pages", systemImage: pdfAsText ? "text.alignleft" : "doc.richtext")
                }
                .help(pdfAsText ? "PDFs open as reflowed text. Click to open them as their original pages."
                                : "PDFs open as their original pages. Click to open them as reflowed text.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showStats = true } label: { Label("Reading", systemImage: "chart.bar") }
                    .help("How much you have been reading")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showDiscover = true } label: { Label("Find Free Books", systemImage: "globe") }
                    .help("Search the open libraries (⇧⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showImporter = true } label: { Label("Add Books", systemImage: "plus") }.help("Add books (⌘O)")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter titles · Return searches inside every book", text: $filter)
                .textFieldStyle(.plain)
                .onSubmit { searchShelf() }
            if searchingShelf { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 10)
        .frame(width: 340)
    }

    /// Tags to narrow the shelf by, and the order the books stand in.
    private var shelfControls: some View {
        HStack(spacing: 8) {
            let tags = library.allTags
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("All", on: tag == nil) { tag = nil }
                        ForEach(tags, id: \.self) { t in chip(t, on: tag == t) { tag = tag == t ? nil : t } }
                    }
                }
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Sort", selection: $orderName) {
                    ForEach(Library.Order.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Text(order.rawValue)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .toolbarCapsule()
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("The order of the shelf")
        }
    }

    private func chip(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name).font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var shelfResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Inside your books: “\(shelfQuery)”").font(.headline)
                Spacer()
                Button("Clear") { shelfQuery = ""; shelfHits = [] }.buttonStyle(.borderless)
            }
            if shelfHits.isEmpty && !searchingShelf {
                Text("No matches.").foregroundStyle(.secondary)
            }
            ForEach(shelfHits) { r in
                Button {
                    guard let entry = library.entry(r.entryID) else { return }
                    model.query = shelfQuery
                    model.open(entry, at: (chapter: r.hit.chapter, block: r.hit.block))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.bookTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(r.hit.snippet).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(HierarchicalShapeStyle.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func searchShelf() {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        shelfQuery = q
        searchingShelf = true
        shelfHits = []
        let entries = library.entries.filter(\.exists)
        Task {
            let found = await Library.searchAll(entries, query: q)
            if shelfQuery == q { shelfHits = found }
            searchingShelf = false
        }
    }
}

struct BookCard: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var model: ReaderModel
    let entry: LibraryEntry
    @State private var hovering = false
    @State private var namingTag = false
    @State private var newTag = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EtherealCover(title: entry.title, author: entry.author, sky: entry.sky, progress: entry.progress,
                          bookmarks: entry.bookmarks.count)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .background {
                    // The shadow belongs to a still shape behind the cover, so it isn't recomputed on every animation frame
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(white: 0.3))
                        .shadow(color: .black.opacity(hovering ? 0.28 : 0.16), radius: hovering ? 10 : 5, y: hovering ? 6 : 3)
                }
                .overlay(alignment: .bottom) {
                    if entry.progress > 0.005 {
                        GeometryReader { g in
                            Capsule().fill(.black.opacity(0.22)).frame(height: 3)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white).frame(width: g.size.width * CGFloat(entry.progress), height: 3)
                                }
                        }
                        .frame(height: 3).padding(8)
                    }
                }
                .scaleEffect(hovering ? 1.02 : 1)
            HStack(spacing: 4) {
                Text(entry.author.isEmpty ? entry.format : entry.author).lineLimit(1)
                if entry.progress > 0.005 { Text("· \(Int((entry.progress * 100).rounded()))%") }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if !entry.labels.isEmpty {
                Text(entry.labels.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !entry.exists {
                Label("File missing", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture { model.open(entry) }
        .contextMenu {
            Button("Read") { model.open(entry) }
            Button("Read Floating") {
                model.open(entry)
                Task {
                    // Wait for the book to finish loading rather than guessing a delay.
                    var waited = 0
                    repeat {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        waited += 1
                    } while model.isLoading && waited < 200
                    model.enterFloat()
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Choose Cover…") { model.coverPick = entry }
            Menu("Tags") {
                ForEach(library.allTags, id: \.self) { t in
                    Toggle(t, isOn: Binding(get: { entry.labels.contains(t) }, set: { _ in library.toggleTag(entry.id, t) }))
                }
                if !library.allTags.isEmpty { Divider() }
                Button("New Tag…") { newTag = ""; namingTag = true }
            }
            Divider()
            Button("Remove from Library", role: .destructive) { library.remove(entry.id) }
            if entry.isOwned {
                Button("Remove and Delete File…", role: .destructive) { confirmDelete = true }
            }
        }
        .alert("New Tag", isPresented: $namingTag) {
            TextField("Name", text: $newTag)
            Button("Add") {
                let name = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !entry.labels.contains(name) { library.toggleTag(entry.id, name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A tag for “\(entry.title)”. Tags gather books into collections on the shelf.")
        }
        .confirmationDialog("Delete “\(entry.title)”?", isPresented: $confirmDelete) {
            Button("Move File to Trash", role: .destructive) { library.remove(entry.id, deleteFile: true) }
        } message: {
            Text("The book leaves the shelf and the file Folio downloaded goes to the Trash.")
        }
        .help("\(entry.title)\n\(entry.words.formatted()) words · \(entry.format)")
    }

}

/// The books in progress, at the head of the shelf: one click carries on where you stopped.
struct ContinueRow: View {
    @EnvironmentObject private var model: ReaderModel
    let entries: [LibraryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTINUE READING").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
            // as many cards as the window has room for, sharing its width equally
            ViewThatFits(in: .horizontal) {
                ForEach((1...max(1, entries.count)).reversed(), id: \.self) { n in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(entries.prefix(n)) { card($0) }
                    }
                }
            }
        }
    }

    private func card(_ e: LibraryEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            EtherealCover(title: e.title, author: e.author, sky: e.sky, progress: e.progress,
                          bookmarks: e.bookmarks.count, animated: false)
                .frame(width: 62)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(e.title).font(.system(size: 14, weight: .semibold, design: .serif)).lineLimit(2)
                if !e.author.isEmpty { Text(e.author).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                ProgressView(value: min(1, max(0, e.progress))).controlSize(.small)
                Text(e.progress > 0.005 ? "\(Int((e.progress * 100).rounded()))% · \(ContinueRow.left(e))" : "Not started")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity, alignment: .leading)   // the ideal width is what ViewThatFits measures
        .background(HierarchicalShapeStyle.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { model.open(e) }
        .help(e.progress > 0.005 ? "Carry on with “\(e.title)”" : "Start “\(e.title)”")
    }

    static func left(_ e: LibraryEntry) -> String {
        if e.page != nil { return "page \((e.page ?? 0) + 1)" }       // pictures of pages: no words to time
        let m = Int((Double(e.words) * (1 - e.progress) / 250).rounded())
        if m < 1 { return "almost done" }
        if m < 60 { return "\(m) min left" }
        return "\(m / 60) h \(m % 60) min left"
    }
}

private extension View {
    /// The look of the capsules the toolbar puts its buttons in.
    @ViewBuilder func toolbarCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.contentShape(Capsule()).glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(HierarchicalShapeStyle.quaternary.opacity(0.5), in: Capsule()).contentShape(Capsule())
        }
    }
}

/// Every sky there is, to choose a book's cover from by hand.
struct CoverGallery: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry
    @State private var filter = ""

    var body: some View {
        let current = library.entry(entry.id)?.sky
        var taken: [Int: String] = [:]
        for e in library.entries where e.id != entry.id { if let s = e.sky { taken[s] = e.title } }
        let q = filter.trimmingCharacters(in: .whitespaces)
        let all = (0..<SkyCatalog.shared.count).filter { q.isEmpty || SkyCatalog.shared.field($0).name.localizedCaseInsensitiveContains(q) }
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a Cover").font(.system(size: 20, weight: .bold, design: .serif))
                    Text(entry.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TextField("Constellation, asterism or object", text: $filter).textFieldStyle(.roundedBorder).frame(width: 240)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 16, alignment: .top)], spacing: 18) {
                    ForEach(all, id: \.self) { i in
                        VStack(spacing: 5) {
                            EtherealCover(title: entry.title, author: entry.author, sky: i, animated: false)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay {
                                    if i == current { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 3).padding(-3) }
                                }
                                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                            Text(SkyCatalog.shared.field(i).name).font(.system(size: 11)).lineLimit(1)
                            if let other = taken[i] {
                                Text("on “\(other)”").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {         // as on the shelf: the cover watches the pointer itself, so a Button around it never fires
                            library.setSky(entry.id, i)
                            dismiss()
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 540, idealHeight: 680)
    }
}
