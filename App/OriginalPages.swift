import CoreImage
import PDFKit
import SwiftUI

/// The reading column for either form of a book: reflowed text, or a PDF's original pages.
struct BookPageView: View {
    let role: ReaderRole
    @EnvironmentObject private var model: ReaderModel
    @AppStorage(Keys.theme) private var themeName = Theme.paper.rawValue
    @AppStorage(Keys.floatTheme) private var floatThemeName = ""
    @AppStorage(Keys.tintPages) private var tintPages = true
    @AppStorage(Keys.twoPages) private var twoPages = false

    private var theme: Theme {
        if role == .float, let t = Theme(rawValue: floatThemeName) { return t }
        return Theme(rawValue: themeName) ?? .paper
    }

    var body: some View {
        if model.showsOriginal, let book = model.book, book.pdf != nil {
            OriginalPages(book: book, role: role, theme: theme, jumpToken: model.jumpToken, selectedHit: model.selectedHit,
                          tinted: tintPages, twoPages: twoPages && role == .window)
                .padding(.top, role == .float ? 22 : 0)        // leaves the float's drag strip free
                .overlay(alignment: .bottom) { if role == .window { RecogniseBar() } }
        } else {
            BookTextView(role: role)
        }
    }
}

extension Notification.Name {
    /// Posted with a Double: above zero zooms the original pages in, below zero out.
    static let folioPageZoom = Notification.Name("FolioPageZoom")
    /// Posted with an Int: 1 turns the original pages a screenful on, -1 back.
    static let folioPageTurn = Notification.Name("FolioPageTurn")
}

/// Offered on a scanned PDF: read the text off its pages so it can be reflowed, searched and read aloud.
struct RecogniseBar: View {
    @EnvironmentObject private var model: ReaderModel

    var body: some View {
        if let book = model.book, let pdf = book.pdf, !pdf.hasText {
            HStack(spacing: 10) {
                if let done = model.recognising {
                    ProgressView(value: done).frame(width: 120)
                    Text("Recognising text… \(Int(done * 100))%").font(.system(size: 12)).monospacedDigit()
                } else {
                    Image(systemName: "text.viewfinder")
                    Text("These pages are pictures.").font(.system(size: 12))
                    Button("Recognise Text") { model.recogniseText() }
                        .controlSize(.small)
                        .help("Read the text off the pages, so the book can be searched, reflowed and read aloud")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.bottom, 14)
        }
    }
}

/// A PDF's own pages, kept in step with the reading position the rest of the app uses.
struct OriginalPages: NSViewRepresentable {
    let book: Book
    let role: ReaderRole
    let theme: Theme
    let jumpToken: UUID
    let selectedHit: SearchHit?
    var tinted = true
    var twoPages = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.autoScales = true
        view.pageShadowsEnabled = role == .window
        if let pdf = book.pdf { view.document = PDFDocument(url: pdf.url) }
        let c = context.coordinator
        c.view = view
        c.role = role
        c.book = book
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.zoom(_:)), name: .folioPageZoom, object: nil)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.turn(_:)), name: .folioPageTurn, object: nil)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Under the tint everything in the view is recoloured, its backdrop too: white there comes out as the theme's page.
        view.backgroundColor = theme == .glass ? .clear : tinted ? .white : NSColor(theme.background)
        let c = context.coordinator
        let mode: PDFDisplayMode = twoPages ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != mode {
            let at = view.currentPage
            view.displayMode = mode
            view.displaysAsBook = twoPages          // the first page stands alone, like a cover
            view.autoScales = true
            if let at, c.token != nil { DispatchQueue.main.async { view.go(to: at) } }
        }
        c.tint(theme: tinted ? theme : nil)
        guard c.token != jumpToken else { return }
        c.token = jumpToken
        let hit = selectedHit
        // The view lays its pages out after this pass; jumping now would land on page one.
        DispatchQueue.main.async { c.jump(to: hit) }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: PDFView?
        var book: Book?
        var role = ReaderRole.window
        var token: UUID?
        /// False until the first jump: a fresh view reports page one before it has been sent anywhere.
        private var placed = false

        func jump(to hit: SearchHit?) {
            placed = true
            let model = ReaderModel.shared
            guard let view, let doc = view.document, let book else { return }
            let wanted = book.pdf?.hasText == false ? model.page : book.page(chapter: model.chapter, block: model.jumpBlock)
            let index = min(max(0, wanted), doc.pageCount - 1)
            guard let page = doc.page(at: index) else { return }
            if let hit, hit.chapter == model.chapter, hit.block == model.jumpBlock, let found = find(hit.match, near: index, in: doc) {
                view.setCurrentSelection(found, animate: true)
                view.go(to: found)
            } else {
                view.clearSelection()
                if view.currentPage !== page { view.go(to: page) }
            }
            model.notePage(doc.index(for: view.currentPage ?? page), from: role)
        }

        /// A paragraph can run over a page break, so the match may sit on the page after the one its paragraph starts on.
        private func find(_ text: String, near index: Int, in doc: PDFDocument) -> PDFSelection? {
            for i in [index, index + 1, index - 1] where i >= 0 && i < doc.pageCount {
                guard let page = doc.page(at: i), let s = page.string else { continue }
                let r = (s as NSString).range(of: text, options: [.caseInsensitive, .diacriticInsensitive])
                if r.location != NSNotFound, let sel = page.selection(for: r) { return sel }
            }
            return nil
        }

        @objc func pageChanged() {
            guard placed, let view, let doc = view.document, let page = view.currentPage else { return }
            ReaderModel.shared.notePage(doc.index(for: page), from: role)
        }

        @objc func turn(_ note: Notification) {
            guard let view, let way = note.object as? Int, view.window?.isVisible == true else { return }
            if way > 0 { view.scrollPageDown(nil) } else { view.scrollPageUp(nil) }
        }

        private var tintedFor: Theme??
        /// Colours the pages like the theme: white paper becomes the theme's page, black ink its text.
        /// A straight line through those two points, so night themes invert the page and pictures with it.
        func tint(theme: Theme?) {
            guard let view, tintedFor != .some(theme) else { return }
            tintedFor = .some(theme)
            guard let theme, theme != .glass,
                  let paper = NSColor(theme.background).usingColorSpace(.sRGB),
                  let ink = NSColor(theme.text).usingColorSpace(.sRGB),
                  let filter = CIFilter(name: "CIColorMatrix") else {
                view.contentFilters = []
                return
            }
            // The filter works on linear light, so the theme's colours are taken out of their sRGB curve first.
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let p = [paper.redComponent, paper.greenComponent, paper.blueComponent].map(linear)
            let k = [ink.redComponent, ink.greenComponent, ink.blueComponent].map(linear)
            filter.setValue(CIVector(x: p[0] - k[0], y: 0, z: 0, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: p[1] - k[1], z: 0, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: p[2] - k[2], w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            filter.setValue(CIVector(x: k[0], y: k[1], z: k[2], w: 0), forKey: "inputBiasVector")
            view.wantsLayer = true
            view.layerUsesCoreImageFilters = true
            view.contentFilters = [filter]
        }

        @objc func zoom(_ note: Notification) {
            guard let view, let delta = note.object as? Double, view.window?.isVisible == true else { return }
            if delta > 0 { view.zoomIn(nil) } else { view.zoomOut(nil) }
        }
    }
}
