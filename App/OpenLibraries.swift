import Foundation

// The free libraries of the web, searched together. Each one below answers a query with books that
// can be downloaded without an account; a chosen book is saved in Folio's own folder and put on the shelf.

enum OpenSource: String, CaseIterable, Identifiable, Sendable {
    case gutenberg, standard, archive, openLibrary, wikisource, arxiv
    var id: String { rawValue }

    var name: String {
        switch self {
        case .gutenberg: return "Project Gutenberg"
        case .standard: return "Standard Ebooks"
        case .archive: return "Internet Archive"
        case .openLibrary: return "Open Library"
        case .wikisource: return "Wikisource"
        case .arxiv: return "arXiv"
        }
    }

    var about: String {
        switch self {
        case .gutenberg: return "75,000 public-domain books, proofread by volunteers"
        case .standard: return "Public-domain classics, carefully typeset"
        case .archive: return "Millions of scanned books; the freely downloadable ones"
        case .openLibrary: return "A catalogue of every book; the public scans"
        case .wikisource: return "Source texts transcribed by Wikimedia volunteers"
        case .arxiv: return "Open scientific papers"
        }
    }
}

struct OpenBook: Identifiable, Hashable, Sendable {
    enum Fetch: Hashable, Sendable {
        case file(URL, ext: String)
        /// Internet Archive items hold several files; the best one is chosen when the book is fetched.
        case archive([String])
    }

    let source: OpenSource
    let key: String
    let title: String
    let author: String
    let detail: String          // year, or what kind of file
    let fetch: Fetch
    var id: String { source.rawValue + ":" + key }
}

enum OpenLibraries {
    enum Failure: LocalizedError {
        case http(Int), notABook, nothingToDownload
        var errorDescription: String? {
            switch self {
            case .http(let code): return "The library answered with error \(code)."
            case .notABook: return "The library sent something that isn't a book."
            case .nothingToDownload: return "This book has no freely downloadable file."
            }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 600
        c.httpAdditionalHeaders = ["User-Agent": "Folio/1.0 (macOS ereader)"]
        return URLSession(configuration: c)
    }()

    private static func get(_ string: String, _ items: [String: String] = [:]) async throws -> Data {
        guard var parts = URLComponents(string: string) else { throw Failure.notABook }
        if !items.isEmpty {
            parts.queryItems = (parts.queryItems ?? []) + items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = parts.url else { throw Failure.notABook }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw Failure.http(http.statusCode) }
        return data
    }

    static func search(_ source: OpenSource, _ query: String) async throws -> [OpenBook] {
        switch source {
        case .gutenberg: return try await gutenberg(query)
        case .standard: return try await standard(query)
        case .archive: return try await archive(query)
        case .openLibrary: return try await openLibrary(query)
        case .wikisource: return try await wikisource(query)
        case .arxiv: return try await arxiv(query)
        }
    }

    /// Subjects offered for browsing; every library that can be browsed files its books under these.
    static let subjects = ["Fiction", "Science Fiction", "Mystery", "Adventure", "Fantasy", "Horror", "Romance", "Children",
                           "Poetry", "Drama", "Humor", "Philosophy", "History", "Biography", "Science", "Travel", "Religion", "Art"]

    /// The libraries that can be browsed without a search: the most downloaded books, of one subject or of all.
    static let browsable: [OpenSource] = [.gutenberg, .standard, .archive, .openLibrary]

    static func browse(_ source: OpenSource, subject: String?) async throws -> [OpenBook] {
        switch source {
        case .gutenberg:
            var items = ["sort_order": "downloads"]
            if let subject { items["query"] = "s.\"\(subject.lowercased())\"" }
            return try await gutenberg(items)
        case .standard:
            guard let subject else { return try await standard("https://standardebooks.org/ebooks", ["sort": "popularity"]) }
            let slug = subject.lowercased().replacingOccurrences(of: " ", with: "-")
            do { return try await standard("https://standardebooks.org/subjects/\(slug)", ["sort": "popularity"]) }
            catch Failure.http(404) { return [] }           // a subject Standard Ebooks does not use
        case .archive:
            return try await archive(matching: subject.map { "subject:\"\($0.lowercased())\"" } ?? "collection:(gutenberg OR americana)")
        case .openLibrary:
            guard let subject else { return [] }
            let slug = subject.lowercased().replacingOccurrences(of: " ", with: "_")
            let data = try await get("https://openlibrary.org/subjects/\(slug).json", ["ebooks": "true", "limit": "40"])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let works = root["works"] as? [[String: Any]] else { return [] }
            return works.compactMap { w in
                guard w["public_scan"] as? Bool == true, let key = w["key"] as? String, let title = w["title"] as? String,
                      let id = w["ia"] as? String, !id.isEmpty else { return nil }
                let authors = (w["authors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                let year = (w["first_publish_year"] as? Int).map(String.init) ?? ""
                return OpenBook(source: .openLibrary, key: key, title: tidy(title), author: tidy(authors.prefix(2).joined(separator: ", ")),
                                detail: year.isEmpty ? "Scan" : "Scan · first published \(year)", fetch: .archive([id]))
            }
        default:
            return []
        }
    }

    // MARK: Project Gutenberg (its OPDS catalogue)

    private static func gutenberg(_ q: String) async throws -> [OpenBook] { try await gutenberg(["query": q]) }

    private static func gutenberg(_ items: [String: String]) async throws -> [OpenBook] {
        let data = try await get("https://www.gutenberg.org/ebooks/search.opds/", items)
        var out: [OpenBook] = []
        for e in Atom.entries(data) {
            guard let id = e.text["id"], let r = id.range(of: #"/ebooks/(\d+)\.opds"#, options: .regularExpression) else { continue }
            let number = id[r].filter(\.isNumber)
            guard let title = e.text["title"], let url = URL(string: "https://www.gutenberg.org/ebooks/\(number).epub3.images") else { continue }
            out.append(OpenBook(source: .gutenberg, key: String(number), title: tidy(title), author: tidy(e.text["content"] ?? ""),
                                detail: "EPUB", fetch: .file(url, ext: "epub")))
        }
        return out
    }

    // MARK: Standard Ebooks (its search page; the catalogue feed is for patrons only)

    private static func standard(_ q: String) async throws -> [OpenBook] {
        try await standard("https://standardebooks.org/ebooks", ["query": q])
    }

    private static func standard(_ page: String, _ items: [String: String]) async throws -> [OpenBook] {
        let data = try await get(page, items)
        let html = String(decoding: data, as: UTF8.self)
        var out: [OpenBook] = []
        let pieces = html.components(separatedBy: "<li typeof=\"schema:Book\" about=\"").dropFirst()
        for piece in pieces {
            guard let end = piece.firstIndex(of: "\"") else { continue }
            let path = String(piece[..<end])                    // /ebooks/herman-melville/moby-dick
            let names = matches(piece, #"property="schema:name">([^<]+)<"#)
            guard path.hasPrefix("/ebooks/"), let title = names.first else { continue }
            let file = path.dropFirst("/ebooks/".count).replacingOccurrences(of: "/", with: "_")
            guard let url = URL(string: "https://standardebooks.org\(path)/downloads/\(file).epub?source=download") else { continue }
            out.append(OpenBook(source: .standard, key: path, title: unescape(title), author: unescape(names.dropFirst().first ?? ""),
                                detail: "EPUB", fetch: .file(url, ext: "epub")))
        }
        return out
    }

    // MARK: Internet Archive

    private static func archive(_ q: String) async throws -> [OpenBook] {
        let words = q.replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: " ", options: .regularExpression)
        return try await archive(matching: "(title:(\(words)) OR creator:(\(words)))")
    }

    private static func archive(matching what: String) async throws -> [OpenBook] {
        let query = what + " AND mediatype:texts AND format:(EPUB OR \"Text PDF\")"
            + " AND NOT collection:(inlibrary OR printdisabled) AND NOT access-restricted-item:true"
        guard var parts = URLComponents(string: "https://archive.org/advancedsearch.php") else { return [] }
        parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "rows", value: "20"),
                            URLQueryItem(name: "output", value: "json"), URLQueryItem(name: "sort[]", value: "downloads desc")]
            + ["identifier", "title", "creator", "year"].map { URLQueryItem(name: "fl[]", value: $0) }
        guard let url = parts.url else { return [] }
        let (data, _) = try await session.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = (root["response"] as? [String: Any])?["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { d in
            guard let id = d["identifier"] as? String, let title = d["title"] as? String else { return nil }
            let year = (d["year"] as? Int).map(String.init) ?? (d["year"] as? String) ?? ""
            return OpenBook(source: .archive, key: id, title: tidy(title), author: strings(d["creator"]).prefix(2).map(person).joined(separator: ", "),
                            detail: year.isEmpty ? "Scan" : "Scan · \(year)", fetch: .archive([id]))
        }
    }

    // MARK: Open Library (the catalogue; its public scans live at the Internet Archive)

    private static func openLibrary(_ q: String) async throws -> [OpenBook] {
        let data = try await get("https://openlibrary.org/search.json",
                                 ["q": q, "limit": "30", "fields": "key,title,author_name,first_publish_year,ia,ebook_access"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let docs = root["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { d in
            guard d["ebook_access"] as? String == "public", let key = d["key"] as? String, let title = d["title"] as? String else { return nil }
            let ids = strings(d["ia"])
            if ids.isEmpty { return nil }
            let year = (d["first_publish_year"] as? Int).map(String.init) ?? ""
            return OpenBook(source: .openLibrary, key: key, title: tidy(title), author: tidy(strings(d["author_name"]).prefix(2).joined(separator: ", ")),
                            detail: year.isEmpty ? "Scan" : "Scan · first published \(year)", fetch: .archive(Array(ids.prefix(6))))
        }
    }

    // MARK: Wikisource (exported as EPUB by Wikimedia's own tool)

    private static func wikisource(_ q: String) async throws -> [OpenBook] {
        let data = try await get("https://en.wikisource.org/w/api.php",
                                 ["action": "query", "list": "search", "srsearch": q, "srnamespace": "0", "srlimit": "12", "format": "json"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = (root["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return [] }
        return found.compactMap { f in
            guard let title = f["title"] as? String, !title.contains("/"), (f["wordcount"] as? Int ?? 0) > 150 else { return nil }
            guard var parts = URLComponents(string: "https://ws-export.wmcloud.org/") else { return nil }
            parts.queryItems = [URLQueryItem(name: "format", value: "epub"), URLQueryItem(name: "lang", value: "en"),
                                URLQueryItem(name: "page", value: title)]
            guard let url = parts.url else { return nil }
            return OpenBook(source: .wikisource, key: title, title: title, author: "", detail: "EPUB", fetch: .file(url, ext: "epub"))
        }
    }

    // MARK: arXiv

    private static func arxiv(_ q: String) async throws -> [OpenBook] {
        let data = try await get("https://export.arxiv.org/api/query", ["search_query": "all:\"\(q)\"", "max_results": "12"])
        return Atom.entries(data).compactMap { e in
            guard let id = e.text["id"], let title = e.text["title"],
                  let pdf = e.links.first(where: { $0.type == "application/pdf" })?.href, var url = URL(string: pdf) else { return nil }
            if url.scheme == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) { c.scheme = "https"; url = c.url ?? url }
            var author = e.authors.prefix(2).joined(separator: ", ")
            if e.authors.count > 2 { author += " et al." }
            let year = String((e.text["published"] ?? "").prefix(4))
            return OpenBook(source: .arxiv, key: id, title: tidy(title), author: tidy(author),
                            detail: year.isEmpty ? "PDF" : "PDF · \(year)", fetch: .file(url, ext: "pdf"))
        }
    }

    // MARK: Fetching a book

    /// Where a book from the web is kept: ~/Library/Application Support/Folio/Books.
    static func destination(for book: OpenBook, ext: String) -> URL {
        let folder = Library.home.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = book.title.replacingOccurrences(of: #"[/:\\\x00-\x1f]"#, with: " ", options: .regularExpression)
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        var hash: UInt64 = 0xCBF29CE484222325
        for b in book.id.utf8 { hash ^= UInt64(b); hash = hash &* 0x100000001B3 }
        return folder.appendingPathComponent("\(name.isEmpty ? "Book" : name) [\(String(hash % 0xFFFFF, radix: 36))].\(ext)")
    }

    /// The file a book was saved to earlier, if it is still there.
    static func saved(_ book: OpenBook) -> URL? {
        ["epub", "pdf"].map { destination(for: book, ext: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Downloads the book into Folio's folder and returns where it is. `progress` is called with 0…1.
    static func download(_ book: OpenBook, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let have = saved(book) { return have }
        var source: URL, ext: String
        switch book.fetch {
        case .file(let url, let e):
            (source, ext) = (url, e)
        case .archive(let ids):
            guard let found = await archiveFile(ids) else { throw Failure.nothingToDownload }
            (source, ext) = found
        }
        let watcher = Watcher(progress)
        let (temp, response) = try await session.download(from: source, delegate: watcher)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw Failure.http(http.statusCode) }
        // Trust the bytes, not the name: an error page saved as a book would only fail later.
        let head = (try? FileHandle(forReadingFrom: temp))?.readData(ofLength: 5) ?? Data()
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { ext = "pdf" }             // %PDF
        else if head.starts(with: [0x50, 0x4B]) { ext = "epub" }                    // a zip
        else { throw Failure.notABook }
        let dest = destination(for: book, ext: ext)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        if ext == "pdf" {
            // PDFs rarely name themselves well; the catalogue knows better.
            BookHints.set(title: book.title, author: book.author, on: dest)
        }
        return dest
    }

    /// The best freely downloadable file of the first Internet Archive item that has one:
    /// the scanned pages with their text if not enormous, else the EPUB made from them.
    private static func archiveFile(_ ids: [String]) async -> (URL, String)? {
        for id in ids {
            guard let data = try? await get("https://archive.org/metadata/\(id)/files"),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = root["result"] as? [[String: Any]] else { continue }
            func pick(_ format: String, under limit: Int) -> String? {
                files.first { f in
                    f["format"] as? String == format && f["private"] == nil && (Int(f["size"] as? String ?? "") ?? 0) < limit
                }?["name"] as? String
            }
            let choice = pick("Text PDF", under: 90_000_000).map { ($0, "pdf") } ?? pick("EPUB", under: 200_000_000).map { ($0, "epub") }
                ?? pick("Text PDF", under: 400_000_000).map { ($0, "pdf") }
            if let (name, ext) = choice, let path = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "https://archive.org/download/\(id)/\(path)") {
                return (url, ext)
            }
        }
        return nil
    }

    private final class Watcher: NSObject, URLSessionDownloadDelegate, Sendable {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    // MARK: Small helpers

    private static func strings(_ any: Any?) -> [String] {
        if let s = any as? String { return [s] }
        return any as? [String] ?? []
    }

    /// Library catalogues file people as "Melville, Herman, 1819-1891"; a reader expects "Herman Melville".
    private static func person(_ s: String) -> String {
        let parts = tidy(s).components(separatedBy: ", ")
        guard parts.count >= 2, parts.count <= 3, !parts[0].contains(" ") || parts.count == 3 else { return tidy(s) }
        if parts.count == 3, parts[2].contains(where: \.isLetter) && !parts[2].hasPrefix("b.") && !parts[2].hasPrefix("d.") { return tidy(s) }
        if parts[1].contains(where: \.isNumber) { return parts[0] }
        return parts[1] + " " + parts[0]
    }

    private static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func unescape(_ s: String) -> String {
        tidy(s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "’").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">"))
    }

    private static func matches(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}

/// A title and author remembered on the file itself (as extended attributes), for files that don't carry their own.
enum BookHints {
    private static let titleKey = "com.fred.folio.title", authorKey = "com.fred.folio.author"

    static func set(title: String, author: String, on url: URL) {
        for (key, value) in [(titleKey, title), (authorKey, author)] where !value.isEmpty {
            let bytes = Array(value.utf8)
            _ = setxattr(url.path, key, bytes, bytes.count, 0, 0)
        }
    }

    static func title(of url: URL) -> String? { read(titleKey, url) }
    static func author(of url: URL) -> String? { read(authorKey, url) }

    private static func read(_ key: String, _ url: URL) -> String? {
        let n = getxattr(url.path, key, nil, 0, 0, 0)
        guard n > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: n)
        guard getxattr(url.path, key, &bytes, n, 0, 0) == n else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Just enough of an Atom reader for the catalogues above.
private final class Atom: NSObject, XMLParserDelegate {
    struct Entry {
        var text: [String: String] = [:]
        var links: [(href: String, type: String)] = []
        var authors: [String] = []
    }

    static func entries(_ data: Data) -> [Entry] {
        let reader = Atom()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.found
    }

    private var found: [Entry] = []
    private var entry: Entry?
    private var buffer = ""
    private var inAuthor = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        buffer = ""
        if name == "entry" { entry = Entry() }
        if name == "author" { inAuthor = true }
        if name == "link", entry != nil, let href = attributes["href"] { entry?.links.append((href, attributes["type"] ?? "")) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "entry":
            if let entry { found.append(entry) }
            entry = nil
        case "author":
            inAuthor = false
        case "name" where inAuthor:
            if !value.isEmpty { entry?.authors.append(value) }
        default:
            if entry != nil, !inAuthor, !value.isEmpty, entry?.text[name] == nil { entry?.text[name] = value }
        }
        buffer = ""
    }
}
