import SwiftUI

/// The reader on an iPhone, or a narrow iPad window: the page fills the screen; contents, search,
/// bookmarks and notes come up on a sheet.
struct PhoneReader: View {
    @EnvironmentObject private var model: ReaderModel
    @EnvironmentObject private var library: Library
    @AppStorage(Keys.theme) private var themeName = Theme.paper.rawValue
    @ObservedObject private var narrator = Narrator.shared
    @State private var showContents = false
    @State private var showAppearance = false

    private var theme: Theme { Theme(rawValue: themeName) ?? .paper }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeBackground(theme: theme).ignoresSafeArea()
                BookPageView(role: .window)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .navigationTitle(model.book?.title ?? "Folio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.closeBook() } label: { Label("Library", systemImage: "books.vertical") }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.sidebarTab = .contents; showContents = true } label: { Label("Contents", systemImage: "list.bullet") }
                    Button { showAppearance = true } label: { Label("Appearance", systemImage: "textformat.size") }
                    Menu {
                        Button { model.toggleBookmark() } label: {
                            Label(model.isBookmarked ? "Remove Bookmark" : "Bookmark", systemImage: model.isBookmarked ? "bookmark.fill" : "bookmark")
                        }
                        Button { model.highlightSelection() } label: { Label("Highlight This Paragraph", systemImage: "highlighter") }
                        Button { model.noteSelection() } label: { Label("Add a Note…", systemImage: "note.text") }
                        Button { narrator.toggle() } label: {
                            Label(narrator.speaking ? "Stop Reading" : "Read Aloud", systemImage: narrator.speaking ? "stop.circle" : "speaker.wave.2")
                        }
                        Button { model.sidebarTab = .search; showContents = true } label: { Label("Search", systemImage: "magnifyingglass") }
                        if model.canSwitchForm {
                            Button { model.toggleOriginal() } label: {
                                Label(model.showsOriginal ? "Show as Text" : "Show Original Pages",
                                      systemImage: model.showsOriginal ? "text.alignleft" : "doc.richtext")
                            }
                        }
                        Divider()
                        Button { model.previousChapter() } label: { Label("Previous Chapter", systemImage: "chevron.left") }
                            .disabled(!model.hasPrevious)
                        Button { model.nextChapter() } label: { Label("Next Chapter", systemImage: "chevron.right") }
                            .disabled(!model.hasNext)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .colorSchemeOverride(theme.colorScheme)
        .sheet(isPresented: $showContents) {
            SidebarView()
                .environmentObject(model).environmentObject(library)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAppearance) {
            NavigationStack {
                ReadingSettings(showFloat: false)
                    .navigationTitle("Appearance")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAppearance = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $model.noteDraft) { NoteEditor(mark: $0).environmentObject(model) }
        .sheet(item: $model.lookUp) { LookUpView(term: $0) }
        // choosing a chapter, a result or a bookmark on the sheet goes there and puts the sheet away
        .onChange(of: model.jumpToken) { _, _ in showContents = false }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let book = model.book {
                Text(book.chapterTitles[min(model.chapter, book.chapterCount - 1)]).lineLimit(1)
                Spacer()
                if model.showsOriginal { Text("Page \(model.page + 1) of \(model.pageCount)").monospacedDigit() }
                Text("\(Int((model.progress * 100).rounded()))%").monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.secondary)
        .padding(.horizontal, 20)
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
        .background(ThemeBackground(theme: theme).ignoresSafeArea(edges: .bottom))
    }
}
