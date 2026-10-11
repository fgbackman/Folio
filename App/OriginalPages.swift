import PDFKit
import SwiftUI

/// The reading column for either form of a book: reflowed text, or a PDF's original pages.
struct BookPageView: View {
    let role: ReaderRole
    @EnvironmentObject private var model: ReaderModel
    @AppStorage(Keys.theme) private var themeName = Theme.paper.rawValue
    @AppStorage(Keys.floatTheme) private var floatThemeName = ""

    private var theme: Theme {
        if role == .float, let t = Theme(rawValue: floatThemeName) { return t }
        return Theme(rawValue: themeName) ?? .paper
    }

    var body: some View {
        if model.showsOriginal, let book = model.book, book.pdf != nil {
            OriginalPages(book: book, role: role, theme: theme, jumpToken: model.jumpToken, selectedHit: model.selectedHit)
                .padding(.top, role == .float ? 22 : 0)        // leaves the float's drag strip free
        } else {
            BookTextView(role: role)
        }
    }
}

extension Notification.Name {
    /// Posted with a Double: above zero zooms the original pages in, below zero out.
    static let folioPageZoom = Notification.Name("FolioPageZoom")
}

/// A PDF's own pages, kept in step with the reading position the rest of the app uses.
struct OriginalPages: NSViewRepresentable {
    let book: Book
    let role: ReaderRole
    let theme: Theme
    let jumpToken: UUID
    let selectedHit: SearchHit?

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
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.backgroundColor = theme == .glass ? .clear : NSColor(theme.background)
        let c = context.coordinator
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
            let index = min(max(0, book.page(chapter: model.chapter, block: model.jumpBlock)), doc.pageCount - 1)
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

        @objc func zoom(_ note: Notification) {
            guard let view, let delta = note.object as? Double, view.window?.isVisible == true else { return }
            if delta > 0 { view.zoomIn(nil) } else { view.zoomOut(nil) }
        }
    }
}
