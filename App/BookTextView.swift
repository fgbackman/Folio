import SwiftUI

/// The reading column. Used by both the main window and the floating book.
struct BookTextView: View {
    let role: ReaderRole
    @EnvironmentObject private var model: ReaderModel
    @ObservedObject private var narrator = Narrator.shared

    @AppStorage(Keys.fontSize) private var fontSize: Double = 19
    @AppStorage(Keys.floatFontSize) private var floatFontSize: Double = 16
    @AppStorage(Keys.font) private var fontName = ReaderFont.newYork.rawValue
    @AppStorage(Keys.theme) private var themeName = Theme.paper.rawValue
    @AppStorage(Keys.floatTheme) private var floatThemeName = ""
    @AppStorage(Keys.lineGap) private var lineGap: Double = 0.38
    @AppStorage(Keys.columnWidth) private var columnWidth: Double = 680
    @AppStorage(Keys.pagedTurns) private var pagedTurns = false

    @State private var topBlock: Int?

    private var size: CGFloat { CGFloat(role == .float ? floatFontSize : fontSize) }
    private var theme: Theme {
        if role == .float, let t = Theme(rawValue: floatThemeName) { return t }
        return Theme(rawValue: themeName) ?? .paper
    }

    var body: some View {
        if let book = model.book {
            let chapter = min(model.chapter, max(0, book.chapterCount - 1))
            let blocks = book.blocks(chapter)
            let hits = model.hitIndex[chapter] ?? [:]
            let marks = model.markIndex[chapter] ?? [:]
            let aloud = narrator.chapter == chapter ? narrator.block : -1
            let font = ReaderFont(rawValue: fontName) ?? .newYork
            let theme = self.theme
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: size * 0.85) {
                        ForEach(blocks) { block in
                            BlockView(block: block, book: book, size: size, font: font, theme: theme,
                                      lineGap: lineGap, hits: hits[block.index] ?? [], selected: model.selectedHit,
                                      marks: marks[block.index] ?? [],
                                      aloud: block.index == aloud, spoken: block.index == aloud ? narrator.spoken : nil)
                                .id(block.index)
                        }
                        ChapterFooter(book: book, chapter: chapter, size: size, font: font, theme: theme)
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, role == .float ? 26 : 56)
                    .padding(.top, role == .float ? 30 : 40)
                    .padding(.bottom, 48)
                    .frame(maxWidth: role == .float ? CGFloat.infinity : CGFloat(columnWidth) + 112)
                    .frame(maxWidth: .infinity)
                    .background(ScrollGrabber(role: role, overlap: size * 1.6))
                }
                // .never also beats "Show scroll bars: Always"
                .scrollIndicators(role == .float || pagedTurns ? .never : .automatic)
                .scrollPosition(id: $topBlock, anchor: .top)
                .id(chapter)
                .task(id: model.jumpToken) {
                    let wanted = model.jumpBlock
                    let anchor = model.jumpAnchor
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if blocks.isEmpty { return }
                    let target = min(wanted, blocks.count - 1)
                    topBlock = target
                    proxy.scrollTo(target, anchor: anchor)
                }
                .onChange(of: topBlock) { _, newValue in
                    if let newValue { model.noteVisible(newValue, from: role) }
                }
            }
            .foregroundStyle(theme.text)
            .tint(theme.text)
        }
    }
}

/// What a link in the text leads to, shown beside it instead of leaving the page.
struct Footnote: Identifiable {
    let id = UUID()
    let text: String
    let chapter: Int
    let block: Int
}

struct BlockView: View {
    let block: Block
    let book: Book
    let size: CGFloat
    let font: ReaderFont
    let theme: Theme
    let lineGap: Double
    let hits: [SearchHit]
    let selected: SearchHit?
    var marks: [Highlight] = []
    var aloud = false
    var spoken: Range<Int>?

    @State private var footnote: Footnote?

    private var content: AttributedString {
        block.attributed(hits: hits, selected: selected, theme: theme, marks: marks, spoken: spoken)
    }
    private var spacing: CGFloat { size * CGFloat(lineGap) }

    var body: some View {
        let notes = marks.compactMap(\.note)
        core
            .background {
                if aloud { RoundedRectangle(cornerRadius: 5).fill(theme.text.opacity(0.05)).padding(-size * 0.35) }
            }
            .overlay(alignment: .topTrailing) {
                if !notes.isEmpty {
                    Image(systemName: "note.text")
                        .font(.system(size: max(10, size * 0.6)))
                        .foregroundStyle(theme.secondary)
                        .offset(x: size * 1.5)
                        .help(notes.joined(separator: "\n\n"))
                        .onTapGesture { ReaderModel.shared.noteDraft = marks.first { $0.note != nil } }
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "folio-link", let i = Int(url.host ?? ""), let link = block.links[safe: i] else { return .systemAction }
                if book.isHeading(chapter: link.chapter, block: link.target) {
                    ReaderModel.shared.go(chapter: link.chapter, block: link.target)      // a contents page, a "see chapter 4"
                } else {
                    footnote = Footnote(text: book.passage(chapter: link.chapter, block: link.target), chapter: link.chapter, block: link.target)
                }
                return .handled
            })
            .popover(item: $footnote, arrowEdge: .bottom) { note in
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView {
                        Text(note.text)
                            .font(font.font(size: min(size, 15)))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    HStack {
                        Spacer()
                        Button("Go There") {
                            footnote = nil
                            ReaderModel.shared.go(chapter: note.chapter, block: note.block)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .frame(width: 360)
            }
    }

    @ViewBuilder private var core: some View {
        switch block.kind {
        case .rule:
            Text("⁂")
                .font(font.font(size: size))
                .foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, size * 0.5)

        case .image:
            BookImage(book: book, path: block.text, maxHeight: max(240, size * 26))

        case .h1, .h2, .h3:
            let scale: CGFloat = block.kind == .h1 ? 1.55 : block.kind == .h2 ? 1.32 : 1.12
            Text(content)
                .font(font.font(size: size * scale).weight(.semibold))
                .lineSpacing(spacing * 0.5)
                .textSelection(.enabled)
                .padding(.top, size * (block.index == 0 ? 0.2 : 1.1))
                .padding(.bottom, size * 0.2)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .quote:
            Text(content)
                .font(font.font(size: size * 0.95))
                .lineSpacing(spacing)
                .textSelection(.enabled)
                .padding(.leading, size)
                .overlay(alignment: .leading) {
                    Rectangle().fill(theme.secondary.opacity(0.5)).frame(width: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

        case .pre:
            Text(content)
                .font(.system(size: size * 0.8, design: .monospaced))
                .lineSpacing(spacing * 0.4)
                .textSelection(.enabled)
                .padding(size * 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

        case .listItem:
            HStack(alignment: .firstTextBaseline, spacing: size * 0.55) {
                Text("•").font(font.font(size: size)).foregroundStyle(theme.secondary)
                Text(content)
                    .font(font.font(size: size))
                    .lineSpacing(spacing)
                    .textSelection(.enabled)
            }
            .padding(.leading, size * 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph:
            Text(content)
                .font(font.font(size: size))
                .lineSpacing(spacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BookImage: View {
    let book: Book
    let path: String
    let maxHeight: CGFloat

    var body: some View {
        if let img = book.image(path) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: min(img.size.width * 2, .infinity), maxHeight: maxHeight)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
    }
}

struct ChapterFooter: View {
    @EnvironmentObject private var model: ReaderModel
    let book: Book
    let chapter: Int
    let size: CGFloat
    let font: ReaderFont
    let theme: Theme

    var body: some View {
        VStack(spacing: 6) {
            Rectangle().fill(theme.secondary.opacity(0.25)).frame(width: 60, height: 1).padding(.bottom, size)
            if chapter + 1 < book.chapterCount {
                Button {
                    model.nextChapter()
                } label: {
                    VStack(spacing: 4) {
                        Text("NEXT").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(theme.secondary)
                        Text(book.chapterTitles[chapter + 1]).font(font.font(size: size * 0.95)).multilineTextAlignment(.center)
                        Image(systemName: "arrow.down").font(.system(size: 11)).foregroundStyle(theme.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text("The End").font(font.font(size: size).italic()).foregroundStyle(theme.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, size * 2)
    }
}
