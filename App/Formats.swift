#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
import PDFKit

/// Books in formats the engine does not read itself. Each is turned once into something it does — HTML, or
/// for comics a PDF of the pages — and kept in Folio's Converted folder beside the PDF conversions.
enum Converted {
    /// Extension → the name the shelf shows for the format.
    static let formats: [String: String] = [
        "fb2": "FictionBook", "mobi": "Kindle", "azw": "Kindle", "azw3": "Kindle", "prc": "Kindle",
        "docx": "Word", "doc": "Word", "rtf": "Rich Text", "odt": "OpenDocument",
    ]
    static let comics: Set<String> = ["cbz"]
    static var extensions: [String] { Array(formats.keys) + Array(comics) }

    private static let version = 4

    enum Failure: LocalizedError {
        case unreadable, protected, unsupported(String), empty
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This file could not be read."
            case .protected: return "This book is copy-protected (DRM), so Folio cannot open it."
            case .unsupported(let what): return what
            case .empty: return "There are no pages in this file."
            }
        }
    }

    /// The HTML made from a book, converting it now if that has not been done.
    static func html(_ url: URL) throws -> URL {
        let (folder, name) = PDFImport.cache(for: url)
        let out = folder.appendingPathComponent("\(name)-v\(version).html")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let fallback = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        let doc: Document
        switch url.pathExtension.lowercased() {
        case "fb2": doc = try FictionBook.read(url)
        case "mobi", "azw", "azw3", "prc": doc = try Kindle.read(url)
        default: doc = try WordProcessor.read(url)
        }
        var head = "<html><head><title>\(escape(doc.title.isEmpty ? fallback : doc.title))</title>"
        if !doc.author.isEmpty { head += "<meta name=\"author\" content=\"\(escape(doc.author))\">" }
        try (head + "</head><body>\n" + doc.body + "\n</body></html>\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// A comic archive as a PDF, one page to a picture.
    static func comic(_ url: URL) throws -> URL {
        #if os(macOS)
        let (folder, name) = PDFImport.cache(for: url)
        let out = folder.appendingPathComponent("\(name)-comic.pdf")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("folio-comic-" + name, isDirectory: true)
        try? FileManager.default.removeItem(at: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, temp.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw Failure.unreadable }

        let kinds: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "bmp", "heic"]
        var pictures: [URL] = []
        if let walk = FileManager.default.enumerator(at: temp, includingPropertiesForKeys: nil) {
            for case let file as URL in walk where kinds.contains(file.pathExtension.lowercased())
                && !file.lastPathComponent.hasPrefix(".") && !file.path.contains("__MACOSX") {
                pictures.append(file)
            }
        }
        pictures.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let pdf = PDFDocument()
        for file in pictures {
            autoreleasepool {
                if let image = NSImage(contentsOf: file), let page = PDFPage(image: image) { pdf.insert(page, at: pdf.pageCount) }
            }
        }
        guard pdf.pageCount > 0 else { throw Failure.empty }
        pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")]
        guard pdf.write(to: out) else { throw Failure.unreadable }
        return out
        #else
        throw Failure.unreadable        // comics are unpacked by a Mac tool; not on iPhone and iPad yet
        #endif
    }

    struct Document { var title = ""; var author = ""; var body = "" }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - FictionBook (FB2): one XML file

private final class FictionBook: NSObject, XMLParserDelegate {
    private var doc = Converted.Document()
    private var path: [String] = []
    private var depth = 0                       // sections inside one another
    private var text = ""
    private var first = "", last = ""
    private var inBody = false, inBinary = false
    private var notes = false

    static func read(_ url: URL) throws -> Converted.Document {
        guard let parser = XMLParser(contentsOf: url) else { throw Converted.Failure.unreadable }
        let me = FictionBook()
        parser.delegate = me
        parser.shouldProcessNamespaces = true
        guard parser.parse() || !me.doc.body.isEmpty else { throw Converted.Failure.unreadable }
        return me.doc
    }

    private var inTitleInfo: Bool { path.contains("title-info") }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(name)
        if name == "binary" { inBinary = true; return }
        if name == "body" {
            inBody = true
            notes = attributes["name"] == "notes"
            return
        }
        guard inBody else { text = ""; return }
        let id = attributes["id"].map { " id=\"\(Converted.escape($0))\"" } ?? ""
        switch name {
        case "section": depth += 1; doc.body += "<div\(id)>\n"
        case "title": doc.body += notes && depth > 0 ? "<p\(id)><b>" : "<h\(min(3, max(1, depth)))\(id)>"
        case "subtitle": doc.body += "<h3\(id)>"
        case "p":
            // a title's lines run together as one heading
            if path.dropLast().last == "title" { if !doc.body.hasSuffix(">") { doc.body += " " } } else { doc.body += "<p\(id)>" }
        case "v": doc.body += "<p\(id)>"
        case "epigraph", "cite", "poem", "annotation": doc.body += "<blockquote\(id)>"
        case "emphasis": doc.body += "<i>"
        case "strong": doc.body += "<b>"
        case "code": doc.body += "<code>"
        case "sup": doc.body += "<sup>"
        case "a":
            let href = attributes.first { $0.key.hasSuffix("href") }?.value ?? ""
            doc.body += "<a href=\"\(Converted.escape(href))\">"
        case "empty-line": doc.body += "<p> </p>"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inBinary { return }
        if inBody { doc.body += Converted.escape(string) } else { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { if path.last == name { path.removeLast() } }
        if name == "binary" { inBinary = false; return }
        if name == "body" { inBody = false; return }
        guard inBody else {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inTitleInfo {
                switch name {
                case "book-title": doc.title = value
                case "first-name": first = value
                case "last-name": last = value
                case "author":
                    let whole = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
                    if doc.author.isEmpty { doc.author = whole }
                    first = ""; last = ""
                default: break
                }
            }
            text = ""
            return
        }
        switch name {
        case "section": depth -= 1; doc.body += "</div>\n"
        case "title": doc.body += notes && depth > 0 ? "</b> " : "</h\(min(3, max(1, depth)))>\n"
        case "subtitle": doc.body += "</h3>\n"
        case "p": if path.dropLast().last != "title" { doc.body += "</p>\n" }
        case "v": doc.body += "</p>\n"
        case "epigraph", "cite", "poem", "annotation": doc.body += "</blockquote>\n"
        case "emphasis": doc.body += "</i>"
        case "strong": doc.body += "</b>"
        case "code": doc.body += "</code>"
        case "sup": doc.body += "</sup>"
        case "a": doc.body += "</a>"
        default: break
        }
    }
}

// MARK: - Word, RTF and OpenDocument: read by the system, then told apart by how they are set

private enum WordProcessor {
    static func read(_ url: URL) throws -> Converted.Document {
        var attrs: NSDictionary?
        guard let text = try? NSAttributedString(url: url, options: [:], documentAttributes: &attrs), text.length > 0 else {
            throw Converted.Failure.unreadable
        }
        var doc = Converted.Document()
        #if os(macOS)
        doc.title = attrs?[NSAttributedString.DocumentAttributeKey.title] as? String ?? ""
        doc.author = attrs?[NSAttributedString.DocumentAttributeKey.author] as? String ?? ""
        #endif

        let ns = text.string as NSString
        struct Para { let range: NSRange; let size: CGFloat; let bold: Bool; let centred: Bool }
        var paras: [Para] = []
        var weight: [Int: Int] = [:]
        var at = 0
        while at < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(r)
            let body = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { continue }
            var size: CGFloat = 12, allBold = true
            text.enumerateAttribute(.font, in: r) { value, run, _ in
                guard let font = value as? NSFont else { return }
                if !ns.substring(with: run).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    size = max(size == 12 ? 0 : size, font.pointSize)
                    if !font.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
                }
            }
            let style = text.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
            paras.append(Para(range: r, size: size, bold: allBold, centred: style?.alignment == .center))
            weight[Int((size * 2).rounded()), default: 0] += body.count
        }
        let common = CGFloat(weight.max { $0.value < $1.value }?.key ?? 24) / 2

        var out = ""
        for p in paras {
            let plain = ns.substring(with: p.range).trimmingCharacters(in: .whitespacesAndNewlines)
            let short = plain.count < 90
            var tag = "p"
            if short && p.size >= common * 1.55 { tag = "h1" }
            else if short && p.size >= common * 1.2 { tag = "h2" }
            else if short && p.bold && plain.count < 70 { tag = "h3" }
            var inner = ""
            text.enumerateAttribute(.font, in: p.range) { value, run, _ in
                var piece = Converted.escape(ns.substring(with: run)).replacingOccurrences(of: "\u{2028}", with: "<br>")
                piece = piece.replacingOccurrences(of: "\n", with: " ")
                let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                if tag == "p", traits.contains(.italic) { piece = "<i>\(piece)</i>" }
                if tag == "p", traits.contains(.bold) { piece = "<b>\(piece)</b>" }
                inner += piece
            }
            out += "<\(tag)>\(inner.trimmingCharacters(in: .whitespaces))</\(tag)>\n"
        }
        // One oversized line at the head is the title page, not a chapter of its own.
        if out.components(separatedBy: "<h1>").count == 2, out.contains("<h2>") {
            out = out.replacingOccurrences(of: "<h2>", with: "<h1>").replacingOccurrences(of: "</h2>", with: "</h1>")
        }
        doc.body = out
        return doc
    }
}

// MARK: - Kindle (MOBI, AZW, AZW3): a Palm database of compressed HTML

private enum Kindle {
    static func read(_ url: URL) throws -> Converted.Document {
        guard let file = try? Data(contentsOf: url, options: .mappedIfSafe), file.count > 78 + 8 else { throw Converted.Failure.unreadable }
        let d = [UInt8](file)
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) << 8 | Int(d[o + 1]) : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) : 0 }

        let kind = String(decoding: d[60..<68], as: UTF8.self)
        guard kind == "BOOKMOBI" || kind == "TEXtREAd" else { throw Converted.Failure.unreadable }
        let count = u16(76)
        guard count > 1, 78 + count * 8 <= d.count else { throw Converted.Failure.unreadable }
        var offsets = (0..<count).map { u32(78 + $0 * 8) }
        offsets.append(d.count)
        func record(_ i: Int) -> ArraySlice<UInt8> {
            guard i >= 0, i < count, offsets[i] <= offsets[i + 1], offsets[i + 1] <= d.count else { return [] }
            return d[offsets[i]..<offsets[i + 1]]
        }

        let r0 = offsets[0]
        let compression = u16(r0), textRecords = u16(r0 + 8), encryption = u16(r0 + 12)
        if encryption != 0 { throw Converted.Failure.protected }
        guard compression == 1 || compression == 2 else {
            throw Converted.Failure.unsupported("This Kindle book uses a compression Folio does not read (Huffman).")
        }

        var doc = Converted.Document()
        var utf8 = false
        var extraFlags = 0
        if kind == "BOOKMOBI", String(decoding: d[(r0 + 16)..<min(d.count, r0 + 20)], as: UTF8.self) == "MOBI" {
            let length = u32(r0 + 20)
            utf8 = u32(r0 + 28) == 65001
            let nameAt = u32(r0 + 84), nameLength = u32(r0 + 88)
            if nameLength > 0, r0 + nameAt + nameLength <= d.count {
                let bytes = Data(d[(r0 + nameAt)..<(r0 + nameAt + nameLength)])
                doc.title = String(data: bytes, encoding: utf8 ? .utf8 : .windowsCP1252) ?? ""
            }
            if length >= 0xE4 { extraFlags = u16(r0 + 0xF2) }
            if u32(r0 + 128) & 0x40 != 0 {                      // an EXTH block of metadata follows the header
                var at = r0 + 16 + length
                if String(decoding: d[at..<min(d.count, at + 4)], as: UTF8.self) == "EXTH" {
                    let items = u32(at + 8)
                    at += 12
                    for _ in 0..<items {
                        let type = u32(at), size = u32(at + 4)
                        guard size >= 8, at + size <= d.count else { break }
                        let value = String(data: Data(d[(at + 8)..<(at + size)]), encoding: utf8 ? .utf8 : .windowsCP1252) ?? ""
                        if type == 100, doc.author.isEmpty { doc.author = value }
                        if type == 503, !value.isEmpty { doc.title = value }
                        at += size
                    }
                }
            }
        }

        var raw: [UInt8] = []
        raw.reserveCapacity(textRecords * 4096)
        for i in 1...max(1, textRecords) where i < count {
            var piece = record(i)
            piece = piece.prefix(max(0, piece.count - trailing(piece, extraFlags)))
            if compression == 2 { expand(piece, into: &raw) } else { raw.append(contentsOf: piece) }
        }
        guard !raw.isEmpty else { throw Converted.Failure.unreadable }
        var html = String(data: Data(raw), encoding: utf8 ? .utf8 : .windowsCP1252) ?? String(decoding: raw, as: UTF8.self)

        // Each part of a newer Kindle book is a whole document with a head of its own; one head is enough.
        for pattern in [#"(?is)<head\b.*?</head>"#, #"(?is)<\?xml.*?\?>"#, #"(?i)</?(html|body)\b[^>]*>"#, #"(?i)<img\b[^>]*>"#] {
            html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        html = html.replacingOccurrences(of: #"(?i)</mbp:pagebreak>"#, with: "", options: .regularExpression)
        // Older Kindle books have no headings, only page breaks: a short line opening a new page is a chapter's title.
        if let opening = try? NSRegularExpression(pattern: #"(?is)<mbp:pagebreak\s*/?>\s*<p\b[^>]*>(.*?)</p>"#) {
            let ns = html as NSString
            var out = "", at = 0
            for m in opening.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let title = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count < 80 else { continue }
                out += ns.substring(with: NSRange(location: at, length: m.range.location - at)) + "<h1>\(title)</h1>"
                at = NSMaxRange(m.range)
            }
            html = out + ns.substring(from: at)
        }
        html = html.replacingOccurrences(of: #"(?i)<mbp:pagebreak\s*/?>"#, with: "<hr>", options: .regularExpression)
        // Kindle books often title their chapters a level or two down.
        func heads(_ tag: String) -> Int { html.components(separatedBy: "<\(tag)").count - 1 }
        if heads("h1") + heads("H1") < 2 {
            let level = heads("h2") + heads("H2") >= 2 ? "2" : heads("h3") + heads("H3") >= 2 ? "3" : ""
            if !level.isEmpty {
                html = html.replacingOccurrences(of: "(?i)<(/?)h\(level)\\b", with: "<$1h1", options: .regularExpression)
            }
        }
        doc.body = html
        return doc
    }

    /// How many bytes at the end of a text record are not text: sizes of extra entries are written
    /// backwards from the record's end, one for each flag set.
    private static func trailing(_ r: ArraySlice<UInt8>, _ flags: Int) -> Int {
        var end = r.count
        let base = r.startIndex
        var f = flags >> 1
        while f != 0 {
            if f & 1 != 0, end > 0 {
                var size = 0
                for i in max(0, end - 4)..<end {
                    let b = Int(r[base + i])
                    if b & 0x80 != 0 { size = 0 }
                    size = size << 7 | (b & 0x7F)
                }
                end -= min(end, size)
            }
            f >>= 1
        }
        if flags & 1 != 0, end > 0 { end -= min(end, Int(r[base + end - 1] & 3) + 1) }
        return r.count - end
    }

    /// PalmDOC compression: literals, runs copied from a little way back, and a space folded into the next letter.
    private static func expand(_ r: ArraySlice<UInt8>, into out: inout [UInt8]) {
        var i = r.startIndex
        let end = r.endIndex
        let start = out.count
        while i < end {
            let c = Int(r[i]); i += 1
            if c == 0 || (c >= 0x09 && c <= 0x7F) {
                out.append(UInt8(c))
            } else if c <= 0x08 {
                let n = min(c, end - i)
                out.append(contentsOf: r[i..<(i + n)])
                i += n
            } else if c >= 0xC0 {
                out.append(0x20)
                out.append(UInt8(c ^ 0x80))
            } else if i < end {
                let pair = c << 8 | Int(r[i]); i += 1
                let distance = (pair >> 3) & 0x7FF, length = (pair & 7) + 3
                guard distance > 0, out.count - start >= distance else { continue }
                for _ in 0..<length { out.append(out[out.count - distance]) }
            }
        }
    }
}
