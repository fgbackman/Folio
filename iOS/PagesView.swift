import PDFKit
import SwiftUI

/// A PDF's own pages on iPhone and iPad, kept in step with the reading position the rest of the app uses.
/// The pages keep their own colours here; the Mac's theme tint has no counterpart in UIKit's PDF view.
struct OriginalPages: UIViewRepresentable {
    let book: Book
    let role: ReaderRole
    let theme: Theme
    let jumpToken: UUID
    let selectedHit: SearchHit?
    var tinted = true
    var twoPages = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.autoScales = true
        if let pdf = book.pdf { view.document = PDFDocument(url: pdf.url) }
        let c = context.coordinator
        c.view = view
        c.role = role
        c.book = book
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.backgroundColor = UIColor(theme.background)
        let c = context.coordinator
        let mode: PDFDisplayMode = twoPages ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != mode {
            let at = view.currentPage
            view.displayMode = mode
            view.displaysAsBook = twoPages
            view.autoScales = true
            if let at, c.token != nil { DispatchQueue.main.async { view.go(to: at) } }
        }
        guard c.token != jumpToken else { return }
        c.token = jumpToken
        let hit = selectedHit
        // The view lays its pages out after this pass; jumping now would land on page one.
        DispatchQueue.main.async { c.jump(to: hit) }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
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
    }
}
