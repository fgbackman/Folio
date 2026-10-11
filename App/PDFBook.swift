import Foundation
import PDFKit

/// A PDF read two ways: its original pages, and its text reflowed like any other book.
/// The text is pulled out once, written as a small HTML file the engine can open, and kept in
/// ~/Library/Application Support/Folio/Converted so the next opening is instant.
struct PDFSource: Sendable {
    let url: URL
    /// The reflowed text the engine opens.
    let html: URL
    /// Where each page's text begins, in bytes of reflowed text; one entry per page.
    let pageStarts: [Int]
    let textLength: Int
    /// False for scans: there are only pictures of pages, so there is nothing to reflow.
    let hasText: Bool

    var pageCount: Int { pageStarts.count }

    /// The page holding the text at `fraction` (0…1) of the way through the book.
    func page(atFraction fraction: Double) -> Int {
        guard pageCount > 1, textLength > 0 else { return 0 }
        let target = Int((min(1, max(0, fraction)) * Double(textLength)).rounded())
        var lo = 0, hi = pageCount - 1                  // the last page starting at or before the target
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pageStarts[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func fraction(atPage page: Int) -> Double {
        guard textLength > 0, pageCount > 0 else { return 0 }
        return Double(pageStarts[min(max(0, page), pageCount - 1)]) / Double(textLength)
    }
}

enum PDFImport {
    /// Bump when the conversion changes, so old conversions are redone.
    private static let version = 4

    private struct Sidecar: Codable {
        let version: Int
        let pageStarts: [Int]
        let textLength: Int
        let hasText: Bool
    }

    enum Failure: LocalizedError {
        case unreadable, locked
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This PDF could not be read."
            case .locked: return "This PDF is protected by a password."
            }
        }
    }

    static func prepare(_ url: URL) throws -> PDFSource {
        let fm = FileManager.default
        let folder = Library.home.appendingPathComponent("Converted", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path)|\(attrs?[.size] as? Int ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        var hash: UInt64 = 0xCBF29CE484222325          // FNV-1a
        for b in stamp.utf8 { hash ^= UInt64(b); hash = hash &* 0x100000001B3 }
        let name = String(hash, radix: 16)
        let html = folder.appendingPathComponent(name + ".html")
        let side = folder.appendingPathComponent(name + ".json")

        if fm.fileExists(atPath: html.path), let data = try? Data(contentsOf: side),
           let s = try? JSONDecoder().decode(Sidecar.self, from: data), s.version == version {
            return PDFSource(url: url, html: html, pageStarts: s.pageStarts, textLength: s.textLength, hasText: s.hasText)
        }

        guard let doc = PDFDocument(url: url) else { throw Failure.unreadable }
        if doc.isLocked { throw Failure.locked }
        let result = Reflow(doc, fallbackTitle: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")).run()
        try result.html.write(to: html, atomically: true, encoding: .utf8)
        let s = Sidecar(version: version, pageStarts: result.pageStarts, textLength: result.textLength, hasText: result.hasText)
        try JSONEncoder().encode(s).write(to: side, options: .atomic)
        return PDFSource(url: url, html: html, pageStarts: s.pageStarts, textLength: s.textLength, hasText: s.hasText)
    }
}

/// Turns the lines PDFKit finds on each page back into paragraphs and headings.
private struct Reflow {
    struct Line {
        let text: String
        let box: CGRect            // page space, y up
        var junk = false           // running head, page number
    }
    struct Mark { let title: String; let level: Int; let y: CGFloat? }
    struct Element { var tag: String; var text: String; let page: Int; var size: CGFloat = 0 }
    struct Result { let html: String; let pageStarts: [Int]; let textLength: Int; let hasText: Bool }

    let doc: PDFDocument
    let fallbackTitle: String

    init(_ doc: PDFDocument, fallbackTitle: String) {
        self.doc = doc
        self.fallbackTitle = fallbackTitle
    }

    func run() -> Result {
        let count = doc.pageCount
        var pages: [[Line]] = []
        var boxes: [CGRect] = []
        pages.reserveCapacity(count)
        for i in 0..<count {
            guard let page = doc.page(at: i) else { pages.append([]); boxes.append(.zero); continue }
            let box = page.bounds(for: .cropBox)
            boxes.append(box)
            var lines: [Line] = []
            if let all = page.selection(for: box) {
                for sel in all.selectionsByLine() {
                    let text = Reflow.clean(sel.string ?? "")
                    if text.isEmpty { continue }
                    lines.append(Line(text: text, box: sel.bounds(for: page)))
                }
            }
            pages.append(lines)
        }

        let letters = pages.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.count } }
        let attrs = doc.documentAttributes ?? [:]
        var title = Reflow.clean(attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "")
        if title.count < 2 || title.lowercased().hasPrefix("untitled") || title.lowercased().hasPrefix("microsoft word") { title = fallbackTitle }
        let author = Reflow.clean(attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "")
        var head = "<html><head><title>\(Reflow.escape(title))</title>"
        if !author.isEmpty { head += "<meta name=\"author\" content=\"\(Reflow.escape(author))\">" }
        head += "</head><body>\n"

        guard letters >= max(40, count * 4) else {
            let note = "This PDF holds pictures of its pages rather than text, so it can only be read in its original pages."
            return Result(html: head + "<p>\(note)</p></body></html>", pageStarts: [Int](repeating: 0, count: count),
                          textLength: note.utf8.count, hasText: false)
        }

        markRunningHeads(&pages, boxes)
        let body = bodyHeight(pages)
        let marks = outline()
        var elements = paragraphs(pages, body: body, marks: marks)
        chapters(&elements, pageCount: count, outlined: !marks.isEmpty)

        var starts = [Int](repeating: 0, count: count)
        var out = head
        var running = 0, next = 0
        for e in elements {
            while next < count && next <= e.page { starts[next] = running; next += 1 }
            out += "<\(e.tag)>\(Reflow.escape(e.text))</\(e.tag)>\n"
            running += e.text.utf8.count
        }
        while next < count { starts[next] = running; next += 1 }
        out += "</body></html>\n"
        return Result(html: out, pageStarts: starts, textLength: running, hasText: true)
    }

    // MARK: Running heads and page numbers

    private func markRunningHeads(_ pages: inout [[Line]], _ boxes: [CGRect]) {
        func edge(_ line: Line, _ box: CGRect) -> Bool {
            box.height > 0 && (line.box.maxY > box.maxY - box.height * 0.09 || line.box.minY < box.minY + box.height * 0.09)
        }
        func key(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
        }
        var seen: [String: Int] = [:]
        for (i, lines) in pages.enumerated() {
            for line in lines where edge(line, boxes[i]) && line.text.count < 90 { seen[key(line.text), default: 0] += 1 }
        }
        /// "Chapter 7: Job Control 83", "84 Bash Reference Manual": a running head carrying the page number.
        /// Returns how far that number is from the page's place in the file.
        func folio(_ s: String, _ index: Int) -> Int? {
            let words = s.split(separator: " ")
            guard words.count >= 2, let first = words.first, let last = words.last else { return nil }
            if let n = Int(last), last.allSatisfy(\.isNumber) { return n - index }
            if let n = Int(first), first.allSatisfy(\.isNumber) { return n - index }
            return nil
        }
        // Page numbers climb in step with the pages, so the same offset turns up again and again.
        var offsets: [Int: Int] = [:]
        for (i, lines) in pages.enumerated() {
            for line in lines where edge(line, boxes[i]) && line.text.count < 90 {
                if let o = folio(line.text, i) { offsets[o, default: 0] += 1 }
            }
        }
        let steady = Set(offsets.filter { $0.value >= max(3, pages.count / 8) }.keys)
        let roman = CharacterSet(charactersIn: "ivxlcdm")
        for i in pages.indices {
            for j in pages[i].indices where edge(pages[i][j], boxes[i]) && pages[i][j].text.count < 90 {
                let k = key(pages[i][j].text)
                let number = k.isEmpty || (k.count <= 7 && k.unicodeScalars.allSatisfy { roman.contains($0) })
                    || k == "page" || (k.hasPrefix("page") && k.hasSuffix("of") && k.count == 6)
                let numbered = folio(pages[i][j].text, i).map { steady.contains($0) } ?? false
                if number || numbered || seen[k, default: 0] >= 3 { pages[i][j].junk = true }
            }
        }
    }

    /// The height of an ordinary line of text: the most common one, counted by letters.
    private func bodyHeight(_ pages: [[Line]]) -> CGFloat {
        var weight: [Int: Int] = [:]
        for lines in pages { for l in lines where !l.junk { weight[Int((l.box.height * 2).rounded()), default: 0] += l.text.count } }
        let best = weight.max { $0.value < $1.value }?.key ?? 24
        return max(4, CGFloat(best) / 2)
    }

    // MARK: Outline

    /// The PDF's own table of contents, by page. Two levels are kept.
    private func outline() -> [Int: [Mark]] {
        guard let root = doc.outlineRoot else { return [:] }
        var flat: [(title: String, depth: Int, page: Int, y: CGFloat?)] = []
        func walk(_ item: PDFOutline, _ depth: Int) {
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                let title = Reflow.clean(child.label ?? "")
                if let dest = child.destination, let page = dest.page, !title.isEmpty {
                    let y = dest.point.y
                    flat.append((title, depth, doc.index(for: page), y >= kPDFDestinationUnspecifiedValue || y <= 0 ? nil : y))
                }
                if depth < 3 { walk(child, depth + 1) }
            }
        }
        walk(root, 0)
        // the shallowest level with at least two entries is the chapter level
        guard let top = (0...3).first(where: { d in flat.filter { $0.depth == d }.count >= 2 }) else { return [:] }
        var marks: [Int: [Mark]] = [:]
        for f in flat where f.depth >= top && f.depth <= top + 1 && f.page >= 0 && f.page < doc.pageCount {
            marks[f.page, default: []].append(Mark(title: f.title, level: f.depth - top, y: f.y))
        }
        return marks
    }

    // MARK: Paragraphs

    private func paragraphs(_ pages: [[Line]], body: CGFloat, marks: [Int: [Mark]]) -> [Element] {
        var out: [Element] = []
        var para = "", paraPage = 0
        var heading = "", headingPage = 0, headingBig = false, headingSize: CGFloat = 0
        var echo = "", echoLeft = 0             // the outline title just written, so its printed twin is dropped

        func flushPara() {
            if !para.isEmpty { out.append(Element(tag: "p", text: para, page: paraPage)) }
            para = ""
        }
        func flushHeading() {
            if !heading.isEmpty { out.append(Element(tag: headingBig ? "h1" : "h2", text: heading, page: headingPage, size: headingSize)) }
            heading = ""
        }
        func plain(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        func ends(_ s: String) -> Bool {
            guard let last = s.unicodeScalars.last else { return true }
            return ".!?:;\"”’)…»".unicodeScalars.contains(last)
        }
        func join(_ a: inout String, _ b: String) {
            if a.isEmpty { a = b; return }
            if a.hasSuffix("-"), let f = b.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(f),
               a.count > 1, a.dropLast().last?.isLetter == true {
                a.removeLast()                  // a word broken across lines
                a += b
            } else {
                a += " " + b
            }
        }

        for (p, all) in pages.enumerated() {
            let lines = all.filter { !$0.junk }
            var pending = (marks[p] ?? []).sorted { ($0.y ?? .greatestFiniteMagnitude) > ($1.y ?? .greatestFiniteMagnitude) }
            let wide = lines.filter { $0.text.count > 30 }
            let left = (wide.isEmpty ? lines : wide).map(\.box.minX).min() ?? 0
            let right = (wide.isEmpty ? lines : wide).map(\.box.maxX).max() ?? 0
            let width = max(1, right - left)

            // a paragraph may run on from the page before, unless that one closed with a full stop
            if ends(para) { flushPara() }
            flushHeading()
            var prev: Line?

            for line in lines {
                while let m = pending.first, m.y == nil || line.box.maxY <= m.y! + body * 0.6 {
                    pending.removeFirst()
                    flushPara(); flushHeading()
                    out.append(Element(tag: m.level == 0 ? "h1" : "h2", text: m.title, page: p))
                    echo = plain(m.title); echoLeft = 3
                    prev = nil
                }
                if echoLeft > 0 {
                    let k = plain(line.text)
                    if !k.isEmpty, line.text.count < 110, echo.contains(k) || (k.contains(echo) && k.count <= echo.count + 12) {
                        echoLeft -= 1
                        continue
                    }
                    echoLeft = 0
                }

                let words = line.text.split(separator: " ").count
                let numeric = line.text.unicodeScalars.allSatisfy { !CharacterSet.letters.contains($0) }
                let big = line.box.height >= body * 1.22 && words <= 14 && !numeric
                let named = Reflow.chapterLike(line.text)
                if marks.isEmpty && (big || named) {
                    flushPara()
                    if !heading.isEmpty, let a = prev, a.box.minY - line.box.maxY > body * 2.5 { flushHeading() }
                    if !heading.isEmpty, abs(line.box.height - headingSize) > 1.5 { flushHeading() }     // a different size is a different heading
                    if heading.isEmpty { headingPage = p; headingBig = false; headingSize = line.box.height }
                    if named { headingBig = true }
                    join(&heading, line.text)
                    prev = line
                    continue
                }
                flushHeading()

                if let a = prev, !para.isEmpty {
                    let gap = a.box.minY - line.box.maxY
                    let indent = body * 0.6
                    let aIn = a.box.minX - left > indent, bIn = line.box.minX - left > indent
                    let aFull = a.box.maxX > right - width * 0.08
                    var fresh = gap > body * 0.7 || line.box.maxY > a.box.maxY + body
                    if bIn && !(aIn && aFull && abs(a.box.minX - line.box.minX) < 2) { fresh = true }
                    if !aFull && a.box.maxX < right - width * 0.12 && ends(a.text) { fresh = true }
                    if fresh { flushPara() }
                }
                if para.isEmpty { paraPage = p }
                join(&para, line.text)
                prev = line
            }
            for m in pending {                  // destinations below the last line of the page
                flushPara(); flushHeading()
                out.append(Element(tag: m.level == 0 ? "h1" : "h2", text: m.title, page: p))
            }
        }
        flushPara(); flushHeading()
        return out
    }

    /// "Chapter 4", "PART TWO", "Book III": a heading even when it is set no larger than the text.
    private static func chapterLike(_ s: String) -> Bool {
        let words = s.lowercased().split(separator: " ")
        guard words.count >= 2, words.count <= 9, ["chapter", "part", "book"].contains(String(words[0])) else { return false }
        let n = words[1].trimmingCharacters(in: CharacterSet(charactersIn: ".:,—–-"))
        if n.isEmpty { return false }
        if n.allSatisfy(\.isNumber) { return true }
        if n.count <= 7 && n.allSatisfy({ "ivxlc".contains($0) }) { return true }
        return ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
                "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"].contains(n)
    }

    // MARK: Chapters

    /// Without an outline the headings found by size decide the chapters; a book with none at all
    /// is cut into runs of pages so no chapter is unmanageably long.
    private func chapters(_ elements: inout [Element], pageCount: Int, outlined: Bool) {
        if outlined { return }
        var tops = elements.filter { $0.tag == "h1" }.count
        if tops < 2 {
            // the largest size of heading used at least twice marks the chapters
            var bySize: [Int: Int] = [:]
            for e in elements where e.tag == "h2" { bySize[Int((e.size * 2).rounded()), default: 0] += 1 }
            if let chapterSize = bySize.filter({ $0.value >= 2 && $0.value <= max(4, pageCount) }).keys.max() {
                for i in elements.indices where elements[i].tag == "h2" && Int((elements[i].size * 2).rounded()) >= chapterSize {
                    elements[i].tag = "h1"
                    tops += 1
                }
            }
        }
        guard tops < 2, pageCount > 30 else { return }
        let run = 20
        var out: [Element] = []
        var cut = 0
        for e in elements {
            if e.page >= cut && e.tag == "p" {
                let last = min(pageCount, cut + run)
                out.append(Element(tag: "h1", text: "Pages \(cut + 1)–\(last)", page: e.page))
                cut = (e.page / run + 1) * run
            }
            out.append(e)
        }
        elements = out
    }

    // MARK: Text

    private static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for u in s.unicodeScalars {
            if u == "\u{AD}" { continue }                                   // soft hyphen
            if CharacterSet.whitespacesAndNewlines.contains(u) || CharacterSet.controlCharacters.contains(u) {
                space = true
                continue
            }
            if space && !out.isEmpty { out.append(" ") }
            space = false
            out.append(u)
        }
        return String(out)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
