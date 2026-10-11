import AppKit
import Foundation

/// Keeps the shelf the same on every Mac signed in to the same iCloud account, through a folder in iCloud Drive.
///
/// The folder (iCloud Drive › Folio) holds a copy of each book's file and one small file, shelf.json, saying
/// where the reader is in each book, with its bookmarks, highlights, tags and cover. Each Mac writes what it
/// knows and takes whatever the other wrote more recently; a book is known by its file's name there.
/// iCloud Drive carries the folder between the Macs. Nothing happens unless syncing is turned on in Settings.
@MainActor
final class ShelfSync: ObservableObject {
    static let shared = ShelfSync()

    struct Record: Codable {
        var file: String
        var title: String
        var author: String
        var chapter = 0
        var block = 0
        var progress: Double = 0
        var page: Int?
        var bookmarks: [Bookmark] = []
        var highlights: [Highlight] = []
        var tags: [String] = []
        var sky: Int?
        var original: Bool?
        var added = Date()
        var lastOpened: Date?
        var modified = Date.distantPast
        var removed = false
    }

    @Published private(set) var status = ""

    private var pending: Task<Void, Never>?
    private var timer: Timer?
    private var running = false
    private var removals: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: "syncRemovals") as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "syncRemovals") }
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Keys.syncShelf) }

    /// iCloud Drive › Folio, if this Mac has iCloud Drive. FOLIO_SYNC points it elsewhere, for trying it out.
    static var folder: URL? {
        if let override = ProcessInfo.processInfo.environment["FOLIO_SYNC"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Folio", isDirectory: true)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { _ in
            MainActor.assumeIsolated { ShelfSync.shared.syncSoon(after: 0) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShelfSync.shared.syncSoon(after: 1) }
        }
        syncSoon(after: 2)
    }

    /// Called whenever the shelf is saved.
    func noteLocalChange() {
        if enabled, !running { syncSoon(after: 15) }
    }

    func noteRemoved(_ entry: LibraryEntry) {
        guard enabled, let name = entry.syncName else { return }
        removals[name] = Date()
        syncSoon(after: 2)
    }

    func syncSoon(after seconds: Double) {
        guard enabled else { status = ""; return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { await sync() }
        }
    }

    private func sync() async {
        guard enabled, !running else { return }
        guard let folder = ShelfSync.folder else { status = "iCloud Drive is not turned on for this Mac."; return }
        running = true
        defer { running = false }
        let fm = FileManager.default
        let books = folder.appendingPathComponent("Books", isDirectory: true)
        try? fm.createDirectory(at: books, withIntermediateDirectories: true)
        let shelf = folder.appendingPathComponent("shelf.json")
        try? fm.startDownloadingUbiquitousItem(at: shelf)

        let decoder = JSONDecoder(), encoder = JSONEncoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var remote: [String: Record] = [:]
        if let data = try? Data(contentsOf: shelf), let list = try? decoder.decode([Record].self, from: data) {
            for r in list { remote[r.file] = r }
        }
        let before = (try? encoder.encode(remote.values.sorted { $0.file < $1.file })) ?? Data()
        let library = Library.shared

        // Books removed here since the last sync
        for (name, when) in removals {
            if var r = remote[name], !r.removed, r.modified < when { r.removed = true; r.modified = when; remote[name] = r }
        }
        if !removals.isEmpty { removals = [:] }

        // This Mac's books: give each a copy in the folder, then let the newer side win
        for entry in library.entries where entry.exists {
            var name = entry.syncName
            if name == nil {
                name = await ShelfSync.place(entry.url, in: books)
                if let name { library.setSyncName(entry.id, name) }
            }
            guard let name else { continue }
            let mine = entry.modified ?? entry.lastOpened ?? entry.added
            if let theirs = remote[name], theirs.modified > mine.addingTimeInterval(1) {
                if theirs.removed {
                    if ReaderModel.shared.entryID != entry.id { library.drop(entry.id) }
                } else {
                    library.adopt(entry.id) { e in
                        e.chapter = theirs.chapter; e.block = theirs.block; e.progress = theirs.progress
                        e.page = theirs.page ?? e.page
                        e.bookmarks = theirs.bookmarks
                        e.highlights = theirs.highlights.isEmpty ? nil : theirs.highlights
                        e.tags = theirs.tags.isEmpty ? nil : theirs.tags
                        e.sky = theirs.sky ?? e.sky
                        e.original = theirs.original ?? e.original
                        e.lastOpened = [e.lastOpened, theirs.lastOpened].compactMap { $0 }.max()
                        e.modified = theirs.modified
                    }
                    if ReaderModel.shared.entryID == entry.id { ReaderModel.shared.refreshMarks() }
                }
            } else {
                remote[name] = Record(file: name, title: entry.title, author: entry.author, chapter: entry.chapter, block: entry.block,
                                      progress: entry.progress, page: entry.page, bookmarks: entry.bookmarks, highlights: entry.marks, tags: entry.labels,
                                      sky: entry.sky, original: entry.original, added: entry.added, lastOpened: entry.lastOpened, modified: mine)
            }
        }

        // The other Mac's books that are not here yet
        let have = Set(library.entries.compactMap(\.syncName))
        var waiting = 0
        for r in remote.values where !r.removed && !have.contains(r.file) {
            let file = books.appendingPathComponent(r.file)
            guard fm.fileExists(atPath: file.path) else {
                // still in the cloud: ask for it and take it up next time round
                let stub = books.appendingPathComponent("." + r.file + ".icloud")
                if fm.fileExists(atPath: stub.path) { try? fm.startDownloadingUbiquitousItem(at: file) }
                waiting += 1
                continue
            }
            guard let entry = await library.add(file) else { continue }
            library.setSyncName(entry.id, r.file)
            library.adopt(entry.id) { e in
                e.chapter = r.chapter; e.block = r.block; e.progress = r.progress
                e.page = r.page
                e.bookmarks = r.bookmarks
                e.highlights = r.highlights.isEmpty ? nil : r.highlights
                e.tags = r.tags.isEmpty ? nil : r.tags
                e.sky = r.sky ?? e.sky
                e.original = r.original
                e.added = r.added
                e.lastOpened = r.lastOpened
                e.modified = r.modified
            }
        }

        let after = (try? encoder.encode(remote.values.sorted { $0.file < $1.file })) ?? Data()
        if after != before { try? after.write(to: shelf, options: .atomic) }
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        status = waiting > 0 ? "Synced at \(stamp) · \(waiting) book\(waiting == 1 ? "" : "s") still coming down from iCloud" : "Synced at \(stamp)"
    }

    /// Copies a book into the shared folder and returns the name it has there. A file already there under
    /// the same name and of the same size is taken to be the same book.
    private static func place(_ url: URL, in books: URL) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let fm = FileManager.default
            if url.deletingLastPathComponent().standardizedFileURL.path == books.standardizedFileURL.path { return url.lastPathComponent }
            let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
            let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            for n in 0..<50 {
                let name = n == 0 ? url.lastPathComponent : "\(base) \(n + 1).\(ext)"
                let dest = books.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) {
                    let there = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int ?? -2
                    if there == size { return name }
                    continue
                }
                if fm.fileExists(atPath: books.appendingPathComponent("." + name + ".icloud").path) { continue }
                do { try fm.copyItem(at: url, to: dest); return name } catch { return nil }
            }
            return nil
        }.value
    }
}
