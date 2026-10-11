import AppKit
import SwiftUI

enum ReaderRole { case window, float }
enum SidebarTab: String, CaseIterable, Identifiable {
    case contents = "Contents", search = "Search", bookmarks = "Bookmarks"
    var id: String { rawValue }
}

/// Everything about the open book and where the reader is in it. Shared by the
/// main window, the floating book, the menu bar item and the Dock menu.
@MainActor
final class ReaderModel: ObservableObject {
    static let shared = ReaderModel()

    // Book and position
    @Published private(set) var book: Book?
    @Published private(set) var entryID: UUID?
    @Published private(set) var chapter = 0
    @Published private(set) var jumpToken = UUID()
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Top visible block. Not published: it changes on every scroll tick.
    private(set) var position = 0
    private(set) var jumpAnchor: UnitPoint = .top
    /// Block the next jump should land on. Kept apart from `position`, which scroll
    /// callbacks overwrite, so a freshly built scroll view can't clobber the target.
    private(set) var jumpBlock = 0
    /// A PDF is being read in its original pages rather than as reflowed text.
    @Published private(set) var showsOriginal = false
    /// Page in view (from 0) while reading original pages.
    @Published private(set) var page = 0

    // Chrome
    @Published private(set) var isFloating = false
    @Published var sidebarTab: SidebarTab = .contents
    @Published var showImporter = false
    @Published var showDiscover = false
    @Published private(set) var searchFocusToken = UUID()

    // Search
    @Published var query = ""
    @Published var options = Book.SearchOptions()
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var hitsTruncated = false
    @Published private(set) var searching = false
    @Published private(set) var selectedHit: SearchHit?
    private(set) var hitIndex: [Int: [Int: [SearchHit]]] = [:]
    private var searchTask: Task<Void, Never>?

    var openMain: (() -> Void)?
    weak var mainWindow: NSWindow?

    private init() {}

    // MARK: - Opening

    func open(url: URL, at target: (chapter: Int, block: Int)? = nil) {
        Task {
            guard let entry = await Library.shared.add(url) else {
                errorMessage = "“\(url.lastPathComponent)” couldn’t be opened as a book."
                return
            }
            open(entry, at: target)
        }
    }

    func open(_ entry: LibraryEntry, at target: (chapter: Int, block: Int)? = nil) {
        if entryID == entry.id, book != nil {
            if let target { go(chapter: target.chapter, block: target.block) }
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { runSearch(immediate: true) }
            return
        }
        savePosition()
        isLoading = true
        errorMessage = nil
        let url = entry.url
        Task {
            let result: Result<Book, Error> = await Task.detached(priority: .userInitiated) {
                Result { try Book(url: url) }
            }.value
            isLoading = false
            switch result {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success(let b):
                book = b
                entryID = entry.id
                hits = []; hitIndex = [:]; selectedHit = nil; hitsTruncated = false
                let ch = min(max(0, target?.chapter ?? entry.chapter), max(0, b.chapterCount - 1))
                chapter = ch
                position = target?.block ?? entry.block
                jumpAnchor = .top
                jumpBlock = position
                if let pdf = b.pdf {
                    showsOriginal = !pdf.hasText || (entry.original ?? true)
                    page = b.page(chapter: ch, block: position)
                } else {
                    showsOriginal = false
                }
                jumpToken = UUID()
                Library.shared.touch(entry.id)
                updateProgress()
                if !query.trimmingCharacters(in: .whitespaces).isEmpty { runSearch(immediate: true) }
            }
        }
    }

    func closeBook() {
        savePosition()
        if isFloating { exitFloat() }
        book = nil
        entryID = nil
        showsOriginal = false
        hits = []; hitIndex = [:]; selectedHit = nil
        progress = 0
    }

    // MARK: - Navigation

    var hasPrevious: Bool { chapter > 0 }
    var hasNext: Bool { (book?.chapterCount ?? 0) > chapter + 1 }

    func go(chapter c: Int, block: Int = 0, anchor: UnitPoint = .top) {
        guard let book, c >= 0, c < book.chapterCount else { return }
        chapter = c
        position = max(0, block)
        jumpAnchor = anchor
        jumpBlock = position
        jumpToken = UUID()
        updateProgress()
        savePosition()
    }

    func nextChapter() { go(chapter: chapter + 1) }
    func previousChapter() { go(chapter: chapter - 1) }

    /// Called by the visible reading view as the user scrolls.
    func noteVisible(_ block: Int, from role: ReaderRole) {
        guard role == (isFloating ? .float : .window), block != position else { return }
        position = block
        updateProgress()
        if let entryID { Library.shared.setPosition(entryID, chapter: chapter, block: position, progress: progress) }
    }

    // MARK: - Original pages

    /// The open book is a PDF with text, so it can be read either way.
    var canSwitchForm: Bool { book?.pdf?.hasText == true }
    var pageCount: Int { book?.pdf?.pageCount ?? 0 }

    /// Switches between a PDF's original pages and its reflowed text, staying at the same place.
    func toggleOriginal() {
        guard canSwitchForm else { return }
        showsOriginal.toggle()
        if let entryID { Library.shared.setOriginal(entryID, showsOriginal) }
        jumpAnchor = .top
        jumpBlock = position
        jumpToken = UUID()
    }

    /// Called by the original pages as they scroll.
    func notePage(_ p: Int, from role: ReaderRole) {
        guard showsOriginal, role == (isFloating ? .float : .window), let book else { return }
        if p != page { page = p }
        // Several places in the text share a page; leave the position alone while it is still on this one.
        if book.page(chapter: chapter, block: position) == p { return }
        let place = book.place(page: p)
        if place.chapter != chapter { chapter = place.chapter }
        position = place.block
        updateProgress()
        if let entryID { Library.shared.setPosition(entryID, chapter: chapter, block: position, progress: progress) }
    }

    private func updateProgress() {
        guard let book, book.totalLength > 0, chapter < book.chapterCount else { progress = 0; return }
        let count = max(1, book.blocks(chapter).count)
        let p = (Double(book.chapterStarts[chapter]) + Double(book.chapterLengths[chapter]) * Double(position) / Double(count))
            / Double(book.totalLength)
        let clamped = min(1, max(0, p))
        if abs(clamped - progress) > 0.0005 { progress = clamped }
    }

    func savePosition() {
        guard let entryID else { return }
        Library.shared.setPosition(entryID, chapter: chapter, block: position, progress: progress)
    }

    var minutesLeft: Int {
        guard let book else { return 0 }
        return Int((Double(book.wordCount) * (1 - progress) / 250).rounded())
    }

    // MARK: - Search

    func focusSearch() {
        sidebarTab = .search
        searchFocusToken = UUID()
    }

    func runSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let book, !q.isEmpty else {
            hits = []; hitIndex = [:]; selectedHit = nil; searching = false; hitsTruncated = false
            return
        }
        let opts = options
        searching = true
        searchTask = Task {
            if !immediate { try? await Task.sleep(nanoseconds: 180_000_000) }
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) {
                book.search(q, options: opts, limit: 3000)
            }.value
            if Task.isCancelled { return }
            hits = result.hits
            hitsTruncated = result.truncated
            var index: [Int: [Int: [SearchHit]]] = [:]
            for h in result.hits { index[h.chapter, default: [:]][h.block, default: []].append(h) }
            hitIndex = index
            selectedHit = nil
            searching = false
        }
    }

    func select(_ hit: SearchHit) {
        selectedHit = hit
        go(chapter: hit.chapter, block: hit.block, anchor: UnitPoint(x: 0.5, y: 0.3))
    }

    func nextHit() { stepHit(1) }
    func previousHit() { stepHit(-1) }

    private func stepHit(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let i: Int
        if let s = selectedHit, let cur = hits.firstIndex(of: s) {
            i = (cur + delta + hits.count) % hits.count
        } else {
            // first hit at or after the current reading position
            i = hits.firstIndex { ($0.chapter, $0.block) >= (chapter, position) } ?? 0
        }
        select(hits[i])
    }

    // MARK: - Bookmarks

    var entry: LibraryEntry? { Library.shared.entry(entryID) }

    var isBookmarked: Bool {
        entry?.bookmarks.contains { $0.chapter == chapter && $0.block == position } ?? false
    }

    func toggleBookmark() {
        guard let book, let entryID else { return }
        if let existing = entry?.bookmarks.first(where: { $0.chapter == chapter && $0.block == position }) {
            Library.shared.removeBookmark(entryID, existing.id)
            return
        }
        let blocks = book.blocks(chapter)
        let text = blocks.indices.contains(position) ? blocks[position].text : book.chapterTitles[chapter]
        let snippet = String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
        Library.shared.addBookmark(entryID, Bookmark(chapter: chapter, block: position,
                                                     snippet: snippet.isEmpty ? book.chapterTitles[chapter] : snippet))
    }

    // MARK: - Floating book

    func toggleFloat() { isFloating ? exitFloat() : enterFloat() }

    func enterFloat() {
        guard book != nil, !isFloating else { return }
        isFloating = true
        FloatController.shared.show()
        mainWindow?.orderOut(nil)
        jumpAnchor = .top
        jumpBlock = position
        jumpToken = UUID()
    }

    func exitFloat() {
        guard isFloating else { return }
        isFloating = false
        FloatController.shared.hide()
        showMainWindow()
        jumpAnchor = .top
        jumpBlock = position
        jumpToken = UUID()
    }

    func showMainWindow() {
        NSApp.activate()
        if let w = mainWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }

    /// Search lives in the window's sidebar, so leave the floating book first.
    func showMainWindowIfNeeded() {
        if isFloating { exitFloat() } else if mainWindow?.isVisible != true { showMainWindow() }
    }

    /// The main window reports itself here; when it closes we forget it so the next
    /// request re-creates it through SwiftUI instead of showing a torn-down window.
    func register(mainWindow w: NSWindow) {
        guard mainWindow !== w else { return }
        mainWindow = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.mainWindow === w { self?.mainWindow = nil }
                self?.savePosition()
            }
        }
    }

    // MARK: - Text size

    func adjustFontSize(_ delta: Double) {
        if showsOriginal { NotificationCenter.default.post(name: .folioPageZoom, object: delta); return }
        let key = isFloating ? Keys.floatFontSize : Keys.fontSize
        let current = UserDefaults.standard.object(forKey: key) as? Double ?? (isFloating ? 16 : 19)
        UserDefaults.standard.set(min(40, max(10, current + delta)), forKey: key)
    }
}
