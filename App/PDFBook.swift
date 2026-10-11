import Foundation
import AppKit
import PDFKit
import Vision

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
        guard pageCount > 1, textLength > 0, hasText else { return 0 }
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
    private static let version = 6

    /// A line of text read off the picture of a page, in page space.
    struct ScannedLine: Codable {
        let text: String
        let x, y, w, h: Double
    }

    private struct Sidecar: Codable {
        let version: Int
        let pageStarts: [Int]
        let textLength: Int
        let hasText: Bool
    }

    enum Failure: LocalizedError {
        case unreadable, locked, noText
        var errorDescription: String? {
            switch self {
            case .noText: return "No text could be recognised on these pages."
            case .unreadable: return "This PDF could not be read."
            case .locked: return "This PDF is protected by a password."
            }
        }
    }

    /// Where conversions are kept, and the name this file's conversion goes by: it changes when the file does.
    static func cache(for url: URL) -> (folder: URL, name: String) {
        let fm = FileManager.default
        let folder = Library.home.appendingPathComponent("Converted", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path)|\(attrs?[.size] as? Int ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        var hash: UInt64 = 0xCBF29CE484222325          // FNV-1a
        for b in stamp.utf8 { hash ^= UInt64(b); hash = hash &* 0x100000001B3 }
        return (folder, String(hash, radix: 16))
    }

    static func prepare(_ url: URL) throws -> PDFSource {
        let fm = FileManager.default
        let (folder, name) = cache(for: url)
        let html = folder.appendingPathComponent(name + ".html")
        let side = folder.appendingPathComponent(name + ".json")

        if fm.fileExists(atPath: html.path), let data = try? Data(contentsOf: side),
           let s = try? JSONDecoder().decode(Sidecar.self, from: data), s.version == version {
            return PDFSource(url: url, html: html, pageStarts: s.pageStarts, textLength: s.textLength, hasText: s.hasText)
        }

        guard let doc = PDFDocument(url: url) else { throw Failure.unreadable }
        if doc.isLocked { throw Failure.locked }
        var reflow = Reflow(doc, fallbackTitle: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "))
        reflow.knownTitle = BookHints.title(of: url)
        reflow.knownAuthor = BookHints.author(of: url)
        reflow.pictures = (folder, name + "-figures")
        // Text recognised earlier on a scan's pages stands in for the text the file lacks.
        if let data = try? Data(contentsOf: folder.appendingPathComponent(name + ".ocr.json")),
           let scanned = try? JSONDecoder().decode([[ScannedLine]].self, from: data) {
            reflow.scanned = scanned
        }
        let result = reflow.run()
        try result.html.write(to: html, atomically: true, encoding: .utf8)
        let s = Sidecar(version: version, pageStarts: result.pageStarts, textLength: result.textLength, hasText: result.hasText)
        try JSONEncoder().encode(s).write(to: side, options: .atomic)
        return PDFSource(url: url, html: html, pageStarts: s.pageStarts, textLength: s.textLength, hasText: s.hasText)
    }
}

extension PDFImport {
    /// Reads the text off the pictures of a scanned PDF's pages (a few seconds a page, several pages at once),
    /// keeps it beside the conversion, and converts the book again with it. `progress` is called with 0…1.
    static func recognise(_ url: URL, progress: @escaping @Sendable (Double) -> Void) throws -> PDFSource {
        guard let first = PDFDocument(url: url) else { throw Failure.unreadable }
        let count = first.pageCount
        let workers = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2, count))
        let lock = NSLock()
        var pages = [[ScannedLine]](repeating: [], count: count)
        var done = 0
        // Each worker reads its own copy of the file and takes every `workers`-th page.
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            guard let doc = w == 0 ? first : PDFDocument(url: url) else { return }
            for i in stride(from: w, to: count, by: workers) {
                var lines: [ScannedLine] = []
                autoreleasepool {
                    guard let page = doc.page(at: i) else { return }
                    let box = page.bounds(for: .cropBox)
                    guard box.width > 1, box.height > 1 else { return }
                    let scale = min(3, 2200 / max(box.width, box.height))
                    guard let image = PageRender.context(page, box: box, rect: box, scale: scale, gray: true)?.makeImage() else { return }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    try? VNImageRequestHandler(cgImage: image).perform([request])
                    for o in request.results ?? [] {
                        guard let best = o.topCandidates(1).first, best.confidence > 0.25 else { continue }
                        let b = o.boundingBox
                        lines.append(ScannedLine(text: best.string, x: box.minX + b.minX * box.width, y: box.minY + b.minY * box.height,
                                                 w: b.width * box.width, h: b.height * box.height))
                    }
                }
                lock.lock()
                pages[i] = lines
                done += 1
                let fraction = Double(done) / Double(max(1, count))
                lock.unlock()
                progress(fraction)
            }
        }
        let letters = pages.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.count } }
        guard letters >= max(40, count * 4) else { throw Failure.noText }
        let (folder, name) = cache(for: url)
        try JSONEncoder().encode(pages).write(to: folder.appendingPathComponent(name + ".ocr.json"), options: .atomic)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".json"))
        return try prepare(url)
    }
}

/// Draws a page, or a part of one, into a bitmap.
enum PageRender {
    static func context(_ page: PDFPage, box: CGRect, rect: CGRect, scale: CGFloat, gray: Bool) -> CGContext? {
        let w = Int((rect.width * scale).rounded(.up)), h = Int((rect.height * scale).rounded(.up))
        guard w > 0, h > 0, w < 12000, h < 12000 else { return nil }
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -(rect.minX - box.minX), y: -(rect.minY - box.minY))
        page.draw(with: .cropBox, to: ctx)
        return ctx
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
    /// From the catalogue the file was downloaded from; better than what PDFs say of themselves.
    var knownTitle: String?
    var knownAuthor: String?
    /// Text recognised on a scan's pages, used in place of the text the PDF lacks.
    var scanned: [[PDFImport.ScannedLine]]?
    /// Where pictures cut out of the pages are saved: a folder, and the name of a folder inside it.
    var pictures: (folder: URL, name: String)?

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
            if let scanned {
                for l in scanned[safe: i] ?? [] {
                    let text = Reflow.clean(l.text)
                    if !text.isEmpty { lines.append(Line(text: text, box: CGRect(x: l.x, y: l.y, width: l.w, height: l.h))) }
                }
            } else if let all = page.selection(for: box) {
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
        if let known = knownTitle, !known.isEmpty { title = known }
        let author = knownAuthor ?? Reflow.clean(attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "")
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
        let figures = scanned == nil ? self.figures(pages, boxes, body: body) : [:]
        var elements = paragraphs(pages, body: body, marks: marks, figures: figures)
        chapters(&elements, pageCount: count, outlined: !marks.isEmpty)

        var starts = [Int](repeating: 0, count: count)
        var out = head
        var running = 0, next = 0
        for e in elements {
            while next < count && next <= e.page { starts[next] = running; next += 1 }
            if e.tag == "img" {
                out += "<img src=\"\(Reflow.escape(e.text))\">\n"
                // the engine counts a picture by the length of its full path
                running += (pictures?.folder.path.utf8.count ?? 0) + 1 + e.text.utf8.count
                continue
            }
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

    // MARK: Pictures

    /// A scan with recognised text laid invisibly over it: every page is one photograph of itself.
    /// Whatever lies between its lines of text is more of the photograph, not a figure.
    private func isScan() -> Bool {
        var looked = 0, photographs = 0
        for i in stride(from: 0, to: doc.pageCount, by: max(1, doc.pageCount / 8)) {
            guard let ref = doc.page(at: i)?.pageRef, let dict = ref.dictionary else { continue }
            looked += 1
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { continue }
            var big = 0
            CGPDFDictionaryApplyBlock(objects, { _, object, info in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) else { return true }
                var w: CGPDFInteger = 0, h: CGPDFInteger = 0
                var kind: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(d, "Subtype", &kind), let kind, String(cString: kind) == "Image",
                   CGPDFDictionaryGetInteger(d, "Width", &w), CGPDFDictionaryGetInteger(d, "Height", &h), w >= 900, h >= 1200 {
                    info?.assumingMemoryBound(to: Int.self).pointee += 1
                }
                return true
            }, &big)
            if big >= 1 { photographs += 1 }
        }
        return looked > 0 && photographs * 5 >= looked * 3
    }

    /// Figures, plates and diagrams: the stretches of a page between its lines of text that are not blank.
    /// Each is cut out of the page as a picture, to be set between the paragraphs it sat between.
    private func figures(_ pages: [[Line]], _ boxes: [CGRect], body: CGFloat) -> [Int: [(top: CGFloat, src: String)]] {
        guard let pictures, pages.count <= 2000, !isScan() else { return [:] }
        let folder = pictures.folder.appendingPathComponent(pictures.name, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        var out: [Int: [(top: CGFloat, src: String)]] = [:]
        var made = 0
        let least = max(body * 5, 64)
        for (p, all) in pages.enumerated() where made < 600 {
            let box = boxes[p]
            guard box.width > 40, box.height > 40, let page = doc.page(at: p) else { continue }
            // the stretches of the page's height that text occupies, top to bottom
            let spans = all.map { (top: $0.box.maxY, bottom: $0.box.minY) }.sorted { $0.top > $1.top }
            var gaps: [(top: CGFloat, bottom: CGFloat)] = []
            var edge = box.maxY - box.height * 0.035
            for s in spans {
                if edge - s.top >= least { gaps.append((edge, s.top)) }
                edge = min(edge, s.bottom)
            }
            let foot = box.minY + box.height * 0.035
            if edge - foot >= least { gaps.append((edge, foot)) }
            if gaps.isEmpty { continue }

            let scale: CGFloat = 0.5
            guard let ctx = PageRender.context(page, box: box, rect: box, scale: scale, gray: true), let data = ctx.data else { continue }
            let w = ctx.width, h = ctx.height, row = ctx.bytesPerRow
            let px = data.bindMemory(to: UInt8.self, capacity: row * h)
            for g in gaps {
                // bitmap rows run from the top of the page down
                let r0 = max(0, Int(((box.maxY - g.top) * scale).rounded(.up)) + 1)
                let r1 = min(h, Int(((box.maxY - g.bottom) * scale).rounded(.down)) - 1)
                if r1 - r0 < 8 { continue }
                var ink = 0, x0 = w, x1 = -1, y0 = h, y1 = -1
                for y in r0..<r1 {
                    let line = px + y * row
                    for x in 0..<w where line[x] < 205 {
                        ink += 1
                        if x < x0 { x0 = x }
                        if x > x1 { x1 = x }
                        if y < y0 { y0 = y }
                        if y > y1 { y1 = y }
                    }
                }
                guard x1 > x0, y1 > y0 else { continue }
                let width = CGFloat(x1 - x0) / scale, height = CGFloat(y1 - y0) / scale
                // a rule, a stray mark or a page number is not a picture
                guard width >= 60, height >= 40, Double(ink) >= Double((x1 - x0) * (y1 - y0)) * 0.012 else { continue }
                let rect = CGRect(x: box.minX + CGFloat(x0) / scale - 3, y: box.maxY - CGFloat(y1) / scale - 3,
                                  width: width + 6, height: height + 6).intersection(box)
                let fine = min(3, max(1, 1500 / rect.width))
                guard let cut = PageRender.context(page, box: box, rect: rect, scale: fine, gray: false)?.makeImage(),
                      let png = NSBitmapImageRep(cgImage: cut).representation(using: .png, properties: [:]) else { continue }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = "p\(p + 1)-\(out[p]?.count ?? 0).png"
                guard (try? png.write(to: folder.appendingPathComponent(file))) != nil else { continue }
                out[p, default: []].append((rect.maxY, pictures.name + "/" + file))
                made += 1
            }
        }
        return out
    }

    // MARK: Paragraphs

    private func paragraphs(_ pages: [[Line]], body: CGFloat, marks: [Int: [Mark]],
                            figures: [Int: [(top: CGFloat, src: String)]] = [:]) -> [Element] {
        var out: [Element] = []
        var waiting: [Element] = []             // pictures met mid-paragraph, set after it
        let loose = scanned != nil              // recognised text: line heights wobble, so only clear headings count
        var para = "", paraPage = 0
        var heading = "", headingPage = 0, headingBig = false, headingSize: CGFloat = 0
        var echo = "", echoLeft = 0             // the outline title just written, so its printed twin is dropped

        func flushPara() {
            if !para.isEmpty { out.append(Element(tag: "p", text: para, page: paraPage)) }
            para = ""
            out += waiting
            waiting = []
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
            var pics = (figures[p] ?? []).sorted { $0.top > $1.top }
            func picture(_ src: String) {
                let e = Element(tag: "img", text: src, page: p)
                if para.isEmpty { flushHeading(); out.append(e) } else { waiting.append(e) }
            }

            for line in lines {
                while let f = pics.first, f.top >= line.box.maxY - 1 { pics.removeFirst(); picture(f.src) }
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
                let letters = line.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                let big = line.box.height >= body * (loose ? 1.6 : 1.22) && words <= (loose ? 9 : 14) && !numeric && letters >= 3
                let named = line.box.width < width * 0.7 && Reflow.chapterLike(line.text)
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
            for f in pics { picture(f.src) }
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
        guard let first = s.first, first.isUppercase, let last = s.last, !",;-".contains(last) else { return false }
        let words = s.lowercased().split(separator: " ")
        guard words.count >= 2, words.count <= 8, ["chapter", "part", "book"].contains(String(words[0])) else { return false }
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
            if u == "\u{AD}" || u == "\u{FFFC}" { continue }               // soft hyphen; the stand-in for an inline picture
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
