import AppKit
import Combine
import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var chapter: Int
    var block: Int
    var snippet: String
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

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// The bookshelf: remembered books, reading positions and bookmarks.
/// Stored as JSON in ~/Library/Application Support/Folio.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var entries: [LibraryEntry] = []

    private let folder: URL
    private let file: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Folio", isDirectory: true)
        file = folder.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data) {
            entries = decoded
        }
    }

    var sorted: [LibraryEntry] {
        entries.sorted { ($0.lastOpened ?? $0.added) > ($1.lastOpened ?? $1.added) }
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
        struct Info: Sendable { let title, author, format: String; let words: Int }
        let info: Info? = await Task.detached(priority: .userInitiated) { () -> Info? in
            guard let book = try? Book(url: URL(fileURLWithPath: path)) else { return nil }
            return Info(title: book.title, author: book.author, format: book.format, words: book.wordCount)
        }.value
        guard let info else { return nil }
        if let existing = entry(forPath: path) { return existing }
        let e = LibraryEntry(id: id, path: path, title: info.title, author: info.author, format: info.format, words: info.words)
        entries.append(e)
        save()
        return e
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
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

    private func update(_ id: UUID, _ change: (inout LibraryEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
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
