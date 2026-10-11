#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Combine
import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var chapter: Int
    var block: Int
    var snippet: String
    var created = Date()
}

/// A passage marked in a book, with an optional note. Offsets are UTF-8 bytes into the block's text.
struct Highlight: Codable, Identifiable, Hashable {
    var id = UUID()
    var chapter: Int
    var block: Int
    var offset: Int
    var length: Int
    var text: String
    var note: String?
    var color = 0
    var created = Date()
}

struct LibraryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var title: String
    var author: String
    var format: String
    var words: Int
    var added = Date()
    var lastOpened: Date?
    var chapter = 0
    var block = 0
    var progress: Double = 0
    var bookmarks: [Bookmark] = []
    /// PDFs only: whether the book was last read in its original pages (nil = not chosen yet).
    var original: Bool?
    /// Which of the skies is on this book's cover. The shelf hands them out so that no two books share one.
    var sky: Int?
    /// Books that are only pictures of pages (scans, comics) have no text to keep a place in; the page is kept instead.
    var page: Int?
    var highlights: [Highlight]?
    var tags: [String]?
    /// Time spent reading this book, and how many of its words went by in that time.
    var seconds: Double?
    var readWords: Double?
    /// When anything about this entry last changed; the newer side wins when two Macs sync.
    var modified: Date?
    /// The file's name in the shared iCloud Drive folder, once the book is synced.
    var syncName: String?

    var marks: [Highlight] { highlights ?? [] }
    var labels: [String] { tags ?? [] }
    /// Downloaded by Folio into its own folder, so Folio may delete the file too.
    var isOwned: Bool {
        url.standardizedFileURL.path.hasPrefix(Library.home.appendingPathComponent("Books").standardizedFileURL.path + "/")
    }
    var url: URL {
        #if !os(macOS)
        // An iPhone or iPad moves the app's folder when the app is updated; the book is found again by its place inside it.
        if let r = path.range(of: "/Folio/Books/") { return Library.home.appendingPathComponent("Books/" + path[r.upperBound...]) }
        #endif
        return URL(fileURLWithPath: path)
    }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// The bookshelf: remembered books, reading positions and bookmarks.
/// Stored as JSON in ~/Library/Application Support/Folio.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var entries: [LibraryEntry] = []

    private let folder: URL
    private let file: URL

    /// Where Folio keeps the shelf, downloaded books and converted PDFs: ~/Library/Application Support/Folio.
    /// Setting FOLIO_HOME points it somewhere else, for trying things out without touching the real shelf.
    /// True when FOLIO_HOME points at a trial shelf; such a shelf keeps out of the Mac's search index.
    nonisolated static let isTrial = !(ProcessInfo.processInfo.environment["FOLIO_HOME"] ?? "").isEmpty

    nonisolated static let home: URL = {
        let fm = FileManager.default
        var url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio", isDirectory: true)
        if let override = ProcessInfo.processInfo.environment["FOLIO_HOME"], !override.isEmpty {
            url = URL(fileURLWithPath: override, isDirectory: true)
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private init() {
        folder = Library.home
        file = folder.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data) {
            entries = decoded
        }
        // Books shelved before covers were handed out keep the constellation they had, where it is still free.
        var changed = false
        for i in entries.indices where entries[i].sky == nil {
            entries[i].sky = freeSky(title: entries[i].title, author: entries[i].author, among: SkyCatalog.firstSkies)
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Covers

    /// A sky no book on the shelf has: the one the title would choose, or failing that the next free one after it.
    /// Once every sky is taken (more books than skies) they are shared, the least used first.
    func freeSky(title: String, author: String, among preferred: Int? = nil) -> Int {
        let count = SkyCatalog.shared.count
        let draw = CoverDesign.draw(title: title, author: author)
        var used = [Int](repeating: 0, count: count)
        for e in entries { if let s = e.sky, s >= 0, s < count { used[s] += 1 } }
        if let preferred, preferred > 0, preferred <= count {
            let first = Int(draw % UInt64(preferred))
            if used[first] == 0 { return first }
        }
        let start = Int(draw % UInt64(count))
        let least = used.min() ?? 0
        for k in 0..<count where used[(start + k) % count] == least { return (start + k) % count }
        return start
    }

    var sorted: [LibraryEntry] { sorted(by: .recent) }

    enum Order: String, CaseIterable, Identifiable {
        case recent = "Recently Read", title = "Title", author = "Author", progress = "Progress", added = "Date Added"
        var id: String { rawValue }
    }

    func sorted(by order: Order) -> [LibraryEntry] {
        func name(_ s: String) -> String {
            let l = s.lowercased()
            for article in ["the ", "a ", "an "] where l.hasPrefix(article) { return String(l.dropFirst(article.count)) }
            return l
        }
        /// "Jane Austen" files under Austen.
        func surname(_ s: String) -> String {
            let first = s.components(separatedBy: ",").first ?? s
            return (first.split(separator: " ").last.map(String.init) ?? "").lowercased()
        }
        switch order {
        case .recent: return entries.sorted { ($0.lastOpened ?? $0.added) > ($1.lastOpened ?? $1.added) }
        case .title: return entries.sorted { name($0.title).localizedStandardCompare(name($1.title)) == .orderedAscending }
        case .author: return entries.sorted {
            let a = surname($0.author), b = surname($1.author)
            if a != b { return a.isEmpty ? false : b.isEmpty ? true : a.localizedStandardCompare(b) == .orderedAscending }
            return name($0.title).localizedStandardCompare(name($1.title)) == .orderedAscending
        }
        case .progress: return entries.sorted { $0.progress > $1.progress }
        case .added: return entries.sorted { $0.added > $1.added }
        }
    }

    /// Every tag in use, in alphabetical order.
    var allTags: [String] {
        Array(Set(entries.flatMap(\.labels))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Books begun and not finished, the latest first.
    func unfinished(_ n: Int) -> [LibraryEntry] {
        Array(entries.filter { $0.lastOpened != nil && $0.progress > 0.005 && $0.progress < 0.985 && $0.exists }
            .sorted { $0.lastOpened! > $1.lastOpened! }.prefix(n))
    }

    /// The books to keep within reach at the top of the shelf: those begun and not finished, then the
    /// rest by how lately they were opened or added. Finished books are left out. Empty if nothing is begun.
    func atHand(_ n: Int) -> [LibraryEntry] {
        var out = unfinished(n)
        guard !out.isEmpty, out.count < n else { return out }
        let have = Set(out.map(\.id))
        out += entries.filter { !have.contains($0.id) && $0.progress < 0.985 && $0.exists }
            .sorted { ($0.lastOpened ?? $0.added) > ($1.lastOpened ?? $1.added) }.prefix(n - out.count)
        return out
    }

    func recent(_ n: Int) -> [LibraryEntry] {
        Array(entries.filter { $0.lastOpened != nil }.sorted { $0.lastOpened! > $1.lastOpened! }.prefix(n))
    }

    func entry(_ id: UUID?) -> LibraryEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    func entry(forPath path: String) -> LibraryEntry? {
        entries.first { $0.path == path }
    }

    /// Adds a book (reading its metadata off the main thread). Returns the existing
    /// entry if the file is already on the shelf.
    @discardableResult
    func add(_ url: URL) async -> LibraryEntry? {
        let path = url.standardizedFileURL.path
        if let existing = entry(forPath: path) { return existing }
        let id = UUID()
        struct Info: Sendable { let title, author, format: String; let words: Int; let text: String }
        let info: Info? = await Task.detached(priority: .userInitiated) { () -> Info? in
            guard let book = try? Book(url: URL(fileURLWithPath: path)) else { return nil }
            return Info(title: book.title, author: book.author, format: book.format, words: book.wordCount, text: book.sample(200_000))
        }.value
        guard let info else { return nil }
        if let existing = entry(forPath: path) { return existing }
        var e = LibraryEntry(id: id, path: path, title: info.title, author: info.author, format: info.format, words: info.words)
        e.sky = freeSky(title: info.title, author: info.author)
        e.modified = Date()
        entries.append(e)
        save()
        Spotlight.index(e, text: info.text)
        FinderCover.apply(to: e)
        return e
    }

    /// Takes a book off the shelf; `deleteFile` also moves its file to the Trash.
    func remove(_ id: UUID, deleteFile: Bool = false) {
        guard let e = entry(id) else { return }
        entries.removeAll { $0.id == id }
        save()
        Spotlight.remove(id)
        ShelfSync.shared.noteRemoved(e)
        if deleteFile { try? FileManager.default.trashItem(at: e.url, resultingItemURL: nil) }
    }

    func setSky(_ id: UUID, _ sky: Int) {
        update(id) { $0.sky = sky }
        if let e = entry(id) { FinderCover.apply(to: e); Spotlight.index(e, text: nil) }
    }

    func setTags(_ id: UUID, _ tags: [String]) {
        update(id) { $0.tags = tags.isEmpty ? nil : tags }
    }

    func toggleTag(_ id: UUID, _ tag: String) {
        guard let e = entry(id) else { return }
        var tags = e.labels
        if let i = tags.firstIndex(of: tag) { tags.remove(at: i) } else { tags.append(tag) }
        setTags(id, tags)
    }

    func addHighlight(_ id: UUID, _ mark: Highlight) {
        update(id) { e in
            var all = e.highlights ?? []
            all.removeAll { $0.chapter == mark.chapter && $0.block == mark.block && $0.offset == mark.offset && $0.length == mark.length }
            all.append(mark)
            all.sort { ($0.chapter, $0.block, $0.offset) < ($1.chapter, $1.block, $1.offset) }
            e.highlights = all
        }
    }

    func removeHighlight(_ id: UUID, _ markID: UUID) {
        update(id) { $0.highlights?.removeAll { $0.id == markID } }
    }

    func setNote(_ id: UUID, _ markID: UUID, _ note: String) {
        update(id) { e in
            guard let i = e.highlights?.firstIndex(where: { $0.id == markID }) else { return }
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            e.highlights?[i].note = trimmed.isEmpty ? nil : trimmed
        }
    }

    func setColor(_ id: UUID, _ markID: UUID, _ color: Int) {
        update(id) { e in
            guard let i = e.highlights?.firstIndex(where: { $0.id == markID }) else { return }
            e.highlights?[i].color = color
        }
    }

    func addReading(_ id: UUID, seconds: Double, words: Double) {
        update(id, stamp: false) { $0.seconds = ($0.seconds ?? 0) + seconds; $0.readWords = ($0.readWords ?? 0) + words }
    }

    /// After a scanned PDF's text has been recognised, the book has words to count.
    func setWords(_ id: UUID, _ words: Int) {
        update(id) { $0.words = words }
    }

    // MARK: - Syncing

    /// Writes another Mac's newer state of a book over this one's.
    func adopt(_ id: UUID, _ change: (inout LibraryEntry) -> Void) {
        update(id, stamp: false, change)
    }

    func setSyncName(_ id: UUID, _ name: String) {
        update(id, stamp: false) { $0.syncName = name }
    }

    /// Takes a book off the shelf because another Mac did; the file stays where it is.
    func drop(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
        Spotlight.remove(id)
    }

    func touch(_ id: UUID) {
        update(id) { $0.lastOpened = Date() }
    }

    func setPosition(_ id: UUID, chapter: Int, block: Int, progress: Double) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let e = entries[i]
        if e.chapter == chapter && e.block == block && abs(e.progress - progress) < 0.0005 { return }
        update(id) { $0.chapter = chapter; $0.block = block; $0.progress = progress }
    }

    func setPage(_ id: UUID, _ page: Int, progress: Double) {
        guard let e = entry(id), e.page != page else { return }
        update(id) { $0.page = page; $0.progress = progress }
    }

    func setOriginal(_ id: UUID, _ original: Bool) {
        update(id) { $0.original = original }
    }

    /// Every PDF on the shelf to open as its own pages, or as text.
    func setAllOriginal(_ original: Bool) {
        for e in entries where e.format.lowercased() == "pdf" && e.original != original { setOriginal(e.id, original) }
    }

    func addBookmark(_ id: UUID, _ mark: Bookmark) {
        update(id) { e in
            if !e.bookmarks.contains(where: { $0.chapter == mark.chapter && $0.block == mark.block }) {
                e.bookmarks.append(mark)
                e.bookmarks.sort { ($0.chapter, $0.block) < ($1.chapter, $1.block) }
            }
        }
    }

    func removeBookmark(_ id: UUID, _ markID: UUID) {
        update(id) { $0.bookmarks.removeAll { $0.id == markID } }
    }

    private func update(_ id: UUID, stamp: Bool = true, _ change: (inout LibraryEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        if stamp { entries[i].modified = Date() }
        scheduleSave()
    }

    private var saveTask: Task<Void, Never>?
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { save() }
        }
    }

    func save() {
        saveTask?.cancel()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(entries) { try? data.write(to: file, options: .atomic) }
        ShelfSync.shared.noteLocalChange()
    }

    // MARK: - Search inside every book

    struct ShelfHit: Identifiable, Hashable, Sendable {
        let id = UUID()
        let entryID: UUID
        let bookTitle: String
        let hit: SearchHit
    }

    static func searchAll(_ entries: [LibraryEntry], query: String, perBook: Int = 6) async -> [ShelfHit] {
        await Task.detached(priority: .userInitiated) {
            var out: [ShelfHit] = []
            for e in entries {
                if Task.isCancelled { break }
                guard let book = try? Book(url: e.url) else { continue }
                for h in book.search(query, options: .init(), limit: perBook).hits {
                    out.append(ShelfHit(entryID: e.id, bookTitle: e.title, hit: h))
                }
            }
            return out
        }.value
    }
}
