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

    private var shown: [LibraryEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let all = library.sorted
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showDiscover = true } label: { Label("Find Free Books", systemImage: "globe") }
                    .help("Search the open libraries (⇧⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showImporter = true } label: { Label("Add Books", systemImage: "plus") }.help("Add books (⌘O)")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library").font(.system(size: 30, weight: .bold, design: .serif))
                Text("\(library.entries.count) book\(library.entries.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter titles · Return searches inside every book", text: $filter)
                    .textFieldStyle(.plain)
                    .onSubmit { searchShelf() }
                if searchingShelf { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .frame(width: 360)
            .background(HierarchicalShapeStyle.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EtherealCover(title: entry.title, author: entry.author, progress: entry.progress,
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
            Divider()
            Button("Remove from Library", role: .destructive) { library.remove(entry.id) }
        }
        .help("\(entry.title)\n\(entry.words.formatted()) words · \(entry.format)")
    }

}
