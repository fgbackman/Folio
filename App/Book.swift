import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Swift face of the C engine. The C side parses the whole book in rd_open and is
/// read-only afterwards, so a Book can be used from any thread.
final class Book: @unchecked Sendable {
    struct TOCItem: Identifiable, Hashable {
        let id: Int
        let title: String
        let chapter: Int
        let block: Int
        let depth: Int
    }

    enum OpenError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let why) = self { return why }
            return nil
        }
    }

    static let contentTypes: [UTType] = ([
        UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub"),
        UTType.plainText,
        UTType.html,
        UTType(filenameExtension: "md"),
        UTType(filenameExtension: "markdown"),
        UTType.pdf,
    ] as [UTType?]).compactMap { $0 }

    let url: URL
    let title: String
    let author: String
    let format: String
    let wordCount: Int
    let chapterTitles: [String]
    let chapterLengths: [Int]
    let chapterStarts: [Int]
    let totalLength: Int
    let toc: [TOCItem]
    /// Set for a PDF: the original pages behind the reflowed text.
    let pdf: PDFSource?

    private let handle: OpaquePointer
    private var cache: [Int: [Block]] = [:]
    private let lock = NSLock()
    private let images = NSCache<NSString, NSImage>()

    init(url: URL) throws {
        let errCap = 256
        var err = [CChar](repeating: 0, count: errCap)
        // A PDF is read through the text pulled out of it; the pages themselves are shown by PDFKit.
        let source: PDFSource? = url.pathExtension.lowercased() == "pdf" ? try PDFImport.prepare(url) : nil
        pdf = source
        guard let h = rd_open((source?.html ?? url).path, &err, errCap) else {
            let why = err.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            throw OpenError.failed(why.isEmpty ? "This file could not be opened." : why)
        }
        handle = h
        self.url = url
        title = String(cString: rd_title(h))
        author = String(cString: rd_author(h))
        format = source == nil ? String(cString: rd_format(h)) : "PDF"
        wordCount = Int(rd_word_count(h))

        let n = Int(rd_chapter_count(h))
        var titles: [String] = [], lengths: [Int] = [], starts: [Int] = []
        var running = 0
        for i in 0..<n {
            titles.append(String(cString: rd_chapter_title(h, Int32(i))))
            let len = Int(rd_chapter_text_len(h, Int32(i)))
            starts.append(running)
            lengths.append(len)
            running += len
        }
        chapterTitles = titles
        chapterLengths = lengths
        chapterStarts = starts
        totalLength = running

        var items: [TOCItem] = []
        for i in 0..<Int(rd_toc_count(h)) {
            items.append(TOCItem(id: i,
                                 title: String(cString: rd_toc_title(h, Int32(i))),
                                 chapter: Int(rd_toc_chapter(h, Int32(i))),
                                 block: Int(rd_toc_block(h, Int32(i))),
                                 depth: Int(rd_toc_depth(h, Int32(i)))))
        }
        toc = items
    }

    deinit { rd_close(handle) }

    var chapterCount: Int { chapterTitles.count }

    /// Styled blocks for a chapter, converted once and cached.
    func blocks(_ chapter: Int) -> [Block] {
        lock.lock()
        if let cached = cache[chapter] { lock.unlock(); return cached }
        lock.unlock()

        var raw: UnsafePointer<rd_block>? = nil
        let n = Int(rd_chapter_blocks(handle, Int32(chapter), &raw))
        var out: [Block] = []
        out.reserveCapacity(n)
        if let raw {
            for i in 0..<n { out.append(Block(index: i, raw: raw[i])) }
        }
        lock.lock()
        cache[chapter] = out
        lock.unlock()
        return out
    }

    // MARK: Original pages

    private var starts: [Int: [Int]] = [:]

    /// Where each block of a chapter begins, in bytes of text from the chapter's start.
    private func blockStarts(_ chapter: Int) -> [Int] {
        lock.lock()
        if let cached = starts[chapter] { lock.unlock(); return cached }
        lock.unlock()
        var out: [Int] = []
        var running = 0
        for b in blocks(chapter) { out.append(running); running += b.text.utf8.count }
        lock.lock()
        starts[chapter] = out
        lock.unlock()
        return out
    }

    /// The PDF page showing a place in the text.
    func page(chapter: Int, block: Int) -> Int {
        guard let pdf, totalLength > 0, chapter >= 0, chapter < chapterCount else { return 0 }
        let s = blockStarts(chapter)
        let within = s.isEmpty ? 0 : s[min(max(0, block), s.count - 1)]
        return pdf.page(atFraction: Double(chapterStarts[chapter] + within) / Double(totalLength))
    }

    /// The place in the text where a PDF page begins.
    func place(page: Int) -> (chapter: Int, block: Int) {
        guard let pdf, totalLength > 0, chapterCount > 0 else { return (0, 0) }
        let offset = Int((pdf.fraction(atPage: page) * Double(totalLength)).rounded())
        let ch = max(0, (chapterStarts.lastIndex { $0 <= offset } ?? 0))
        let s = blockStarts(ch)
        // the first block that reaches onto the page
        let block = s.firstIndex { $0 >= offset - chapterStarts[ch] } ?? max(0, s.count - 1)
        return (ch, block)
    }

    func image(_ path: String) -> NSImage? {
        if let cached = images.object(forKey: path as NSString) { return cached }
        var len = 0
        guard let bytes = rd_resource(handle, path, &len) else { return nil }
        let data = Data(bytes: bytes, count: len)
        rd_free(bytes)
        guard let img = NSImage(data: data) else { return nil }
        images.setObject(img, forKey: path as NSString)
        return img
    }

    func coverData() -> Data? {
        var len = 0
        guard let bytes = rd_cover(handle, &len) else { return nil }
        defer { rd_free(bytes) }
        return Data(bytes: bytes, count: len)
    }

    struct SearchOptions: Equatable {
        var matchCase = false
        var wholeWord = false
        var allWords = false
        var flags: Int32 {
            (matchCase ? RD_SEARCH_MATCH_CASE : 0) | (wholeWord ? RD_SEARCH_WHOLE_WORD : 0) | (allWords ? RD_SEARCH_ALL_WORDS : 0)
        }
    }

    /// Full-text search. Returns hits in reading order and whether the limit was hit.
    func search(_ query: String, options: SearchOptions, limit: Int) -> (hits: [SearchHit], truncated: Bool) {
        guard limit > 0 else { return ([], false) }
        var raw = [rd_hit](repeating: rd_hit(), count: limit)
        let n = Int(rd_search(handle, query, options.flags, &raw, Int32(limit)))
        var hits: [SearchHit] = []
        hits.reserveCapacity(n)
        for i in 0..<n {
            let r = raw[i]
            let ch = Int(r.chapter), bl = Int(r.block)
            let blocks = self.blocks(ch)
            guard bl < blocks.count else { continue }
            let (before, match, after) = Block.snippet(text: blocks[bl].text, offset: Int(r.offset), length: Int(r.length))
            hits.append(SearchHit(id: i, chapter: ch, block: bl, offset: Int(r.offset), length: Int(r.length),
                                  before: before, match: match, after: after))
        }
        hits.sort { ($0.chapter, $0.block, $0.offset) < ($1.chapter, $1.block, $1.offset) }
        return (hits, n >= limit)
    }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let id: Int
    let chapter: Int
    let block: Int
    let offset: Int
    let length: Int
    let before: String
    let match: String
    let after: String

    var snippet: AttributedString {
        var a = AttributedString(before)
        var m = AttributedString(match)
        m.inlinePresentationIntent = .stronglyEmphasized
        m.swiftUI.backgroundColor = Color.yellow.opacity(0.35)
        a.append(m)
        a.append(AttributedString(after))
        return a
    }
}

struct Block: Identifiable {
    enum Kind { case paragraph, h1, h2, h3, quote, pre, listItem, rule, image }

    let index: Int
    let kind: Kind
    let text: String
    let styled: AttributedString
    var id: Int { index }

    init(index: Int, raw: rd_block) {
        self.index = index
        switch raw.type {
        case RD_H1: kind = .h1
        case RD_H2: kind = .h2
        case RD_H3: kind = .h3
        case RD_QUOTE: kind = .quote
        case RD_PRE: kind = .pre
        case RD_LI: kind = .listItem
        case RD_HR: kind = .rule
        case RD_IMG: kind = .image
        default: kind = .paragraph
        }
        let text = raw.text.map { String(cString: $0) } ?? ""
        self.text = text
        var a = AttributedString(text)
        if raw.span_count > 0, let spans = raw.spans {
            for j in 0..<Int(raw.span_count) {
                let s = spans[j]
                guard let r = Block.range(in: a, text: text, start: Int(s.start), length: Int(s.length)) else { continue }
                var intent: InlinePresentationIntent = []
                if s.style & RD_STYLE_ITALIC != 0 { intent.insert(.emphasized) }
                if s.style & RD_STYLE_BOLD != 0 { intent.insert(.stronglyEmphasized) }
                if s.style & RD_STYLE_CODE != 0 { intent.insert(.code) }
                a[r].inlinePresentationIntent = intent
            }
        }
        self.styled = a
    }

    /// The block's text with search matches painted in.
    func attributed(hits: [SearchHit], selected: SearchHit?, theme: Theme) -> AttributedString {
        guard !hits.isEmpty else { return styled }
        var a = styled
        for h in hits {
            guard let r = Block.range(in: a, text: text, start: h.offset, length: h.length) else { continue }
            a[r].swiftUI.backgroundColor = (h == selected) ? theme.selectedHighlight : theme.highlight
        }
        return a
    }

    /// Converts a UTF-8 byte range from the C engine into an AttributedString range.
    static func range(in a: AttributedString, text: String, start: Int, length: Int) -> Range<AttributedString.Index>? {
        let u = text.utf8
        guard start >= 0, length > 0, start + length <= u.count else { return nil }
        let i0 = u.index(u.startIndex, offsetBy: start)
        let i1 = u.index(i0, offsetBy: length)
        let scalars = text.unicodeScalars
        let s0 = scalars.distance(from: scalars.startIndex, to: i0)
        let s1 = scalars.distance(from: scalars.startIndex, to: i1)
        let view = a.unicodeScalars
        guard s1 <= view.count else { return nil }
        let a0 = view.index(view.startIndex, offsetBy: s0)
        let a1 = view.index(view.startIndex, offsetBy: s1)
        return a0..<a1
    }

    static func snippet(text: String, offset: Int, length: Int) -> (String, String, String) {
        let u = text.utf8
        guard offset >= 0, offset + length <= u.count else { return ("", "", "") }
        let i0 = u.index(u.startIndex, offsetBy: offset)
        let i1 = u.index(i0, offsetBy: length)
        let head = text[..<i0], tail = text[i1...]
        var before = String(head.suffix(55))
        var after = String(tail.prefix(90))
        if head.count > 55 { before = "…" + before }
        if tail.count > 90 { after += "…" }
        func flat(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
        return (flat(before), flat(String(text[i0..<i1])), flat(after))
    }
}
