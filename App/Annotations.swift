#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import UniformTypeIdentifiers

enum HighlightColor {
    static let names = ["Yellow", "Green", "Blue", "Pink"]

    static func color(_ index: Int, dark: Bool) -> Color {
        let a = dark ? 0.38 : 0.50
        switch index {
        case 1: return Color(red: 0.45, green: 0.85, blue: 0.45).opacity(a)
        case 2: return Color(red: 0.45, green: 0.70, blue: 1.00).opacity(a)
        case 3: return Color(red: 1.00, green: 0.55, blue: 0.75).opacity(a)
        default: return Color(red: 1.00, green: 0.86, blue: 0.25).opacity(a)
        }
    }
}

/// The text selected on the page. SwiftUI keeps a selection to itself, so it is read the way the
/// Edit menu reads it: the view holding it is asked to copy, and the clipboard is put back afterwards.
enum PageSelection {
    @MainActor static func current() -> String? {
        #if os(macOS)
        let board = NSPasteboard.general
        let kept: [[NSPasteboard.PasteboardType: Data]] = (board.pasteboardItems ?? []).map { item in
            var out: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { out[type] = d } }
            return out
        }
        let before = board.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        guard board.changeCount != before else { return nil }
        let text = board.string(forType: .string)
        board.clearContents()
        let items = kept.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
        #else
        return nil      // the selection can't be read this way on iPhone and iPad
        #endif
    }
}

extension ReaderModel {
    /// Where a run of selected text sits in the open chapter, looking first at what is on screen.
    private func locate(_ selection: String) -> (block: Int, offset: Int, length: Int, text: String)? {
        guard let book else { return nil }
        let blocks = book.blocks(chapter)
        guard !blocks.isEmpty else { return nil }
        let from = max(0, min(position, blocks.count - 1) - 2)
        let order = Array(from..<blocks.count) + Array(0..<from)
        func find(_ needle: String) -> (Int, Int, Int, String)? {
            guard !needle.isEmpty else { return nil }
            for i in order where blocks[i].kind != .image && blocks[i].kind != .rule {
                let text = blocks[i].text
                guard let r = text.range(of: needle) else { continue }
                let start = text.utf8.distance(from: text.utf8.startIndex, to: r.lowerBound)
                return (i, start, text[r].utf8.count, String(text[r]))
            }
            return nil
        }
        if let hit = find(selection) { return hit }
        // Original pages break lines where the reflowed text has spaces.
        let flat = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let hit = find(flat) { return hit }
        // A selection running over a page's line-end hyphens: its opening words are enough to place it.
        let opening = flat.split(separator: " ").prefix(6).joined(separator: " ")
        return opening.count >= 12 ? find(opening) : nil
    }

    /// Marks the selected text, or the paragraph at the top of the page when nothing is selected.
    @discardableResult
    func highlightSelection(color: Int = 0) -> Highlight? {
        guard let book, let entryID else { return nil }
        var mark: Highlight?
        if let selection = PageSelection.current() {
            guard let at = locate(selection) else { NSSound.beep(); return nil }
            mark = Highlight(chapter: chapter, block: at.block, offset: at.offset, length: at.length, text: at.text, color: color)
        } else {
            let blocks = book.blocks(chapter)
            guard let b = blocks[safe: position] ?? blocks.first, b.kind != .image, b.kind != .rule, !b.text.isEmpty else { NSSound.beep(); return nil }
            mark = Highlight(chapter: chapter, block: b.index, offset: 0, length: b.text.utf8.count, text: b.text, color: color)
        }
        guard let mark else { return nil }
        // Marking the same words again takes the mark away.
        if let same = entry?.marks.first(where: { $0.chapter == mark.chapter && $0.block == mark.block && $0.offset == mark.offset && $0.length == mark.length }),
           same.note == nil, same.color == color {
            Library.shared.removeHighlight(entryID, same.id)
            refreshMarks()
            return nil
        }
        Library.shared.addHighlight(entryID, mark)
        refreshMarks()
        return mark
    }

    func noteSelection() {
        guard let mark = highlightSelection() ?? lastMarkOnPage() else { return }
        noteDraft = mark
    }

    private func lastMarkOnPage() -> Highlight? {
        entry?.marks.last { $0.chapter == chapter && $0.block >= position }
    }

    func saveNote(_ mark: Highlight, _ text: String) {
        guard let entryID else { return }
        Library.shared.setNote(entryID, mark.id, text)
        refreshMarks()
    }

    func recolor(_ mark: Highlight, _ color: Int) {
        guard let entryID else { return }
        Library.shared.setColor(entryID, mark.id, color)
        refreshMarks()
    }

    func remove(_ mark: Highlight) {
        guard let entryID else { return }
        Library.shared.removeHighlight(entryID, mark.id)
        refreshMarks()
    }

    func lookUpSelection() {
        guard let selection = PageSelection.current() else { NSSound.beep(); return }
        let words = selection.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        lookUp = LookUpTerm(text: words.trimmingCharacters(in: .punctuationCharacters))
    }

    /// Highlights and notes as a Markdown document, chapter by chapter.
    func marksAsMarkdown() -> String {
        guard let book, let entry else { return "" }
        var out = "# \(book.title)\n"
        if !book.author.isEmpty { out += "*\(book.author)*\n" }
        var chapter = -1
        for m in entry.marks {
            if m.chapter != chapter {
                chapter = m.chapter
                out += "\n## \(book.chapterTitles[safe: chapter] ?? "Chapter \(chapter + 1)")\n"
            }
            out += "\n> " + m.text.replacingOccurrences(of: "\n", with: "\n> ") + "\n"
            if let note = m.note { out += "\n" + note + "\n" }
        }
        if !entry.bookmarks.isEmpty {
            out += "\n## Bookmarks\n\n"
            for b in entry.bookmarks { out += "- \(book.chapterTitles[safe: b.chapter] ?? ""): \(b.snippet)\n" }
        }
        return out
    }

    #if os(macOS)
    func exportMarks() {
        guard let book else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = book.title.replacingOccurrences(of: "/", with: "-") + " – notes.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let text = marksAsMarkdown()
        panel.begin { answer in
            guard answer == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #endif
}

// MARK: - Sidebar

struct NotesList: View {
    @EnvironmentObject private var model: ReaderModel
    @EnvironmentObject private var library: Library
    @AppStorage(Keys.theme) private var themeName = Theme.paper.rawValue

    var body: some View {
        let marks = library.entry(model.entryID)?.marks ?? []
        let dark = (Theme(rawValue: themeName) ?? .paper).isDark
        VStack(spacing: 0) {
            if marks.isEmpty {
                ContentUnavailableView("No Highlights", systemImage: "highlighter",
                                       description: Text("Select some text and press ⌃⌘H to highlight it, or ⌃⌘N to write a note on it."))
            } else {
                List {
                    ForEach(marks) { mark in
                        Button { model.go(chapter: mark.chapter, block: mark.block, anchor: UnitPoint(x: 0.5, y: 0.25)) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5).fill(HighlightColor.color(mark.color, dark: false).opacity(1)).frame(width: 3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.book?.chapterTitles[safe: mark.chapter] ?? "")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(mark.text).font(.system(size: 12)).lineLimit(4)
                                    if let note = mark.note {
                                        Text(note).font(.system(size: 12).italic()).foregroundStyle(.secondary).lineLimit(6)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(mark.note == nil ? "Add Note…" : "Edit Note…") { model.noteDraft = mark }
                            Menu("Colour") {
                                ForEach(HighlightColor.names.indices, id: \.self) { i in
                                    Button(HighlightColor.names[i]) { model.recolor(mark, i) }
                                }
                            }
                            Button("Copy") {
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(mark.text, forType: .string)
                                #else
                                UIPasteboard.general.string = mark.text
                                #endif
                            }
                            Divider()
                            Button("Remove Highlight", role: .destructive) { model.remove(mark) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .id(dark)
                Divider()
                HStack {
                    Text("\(marks.count) highlight\(marks.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    #if os(macOS)
                    Button("Export…") { model.exportMarks() }.controlSize(.small).help("Save highlights and notes as Markdown")
                    #else
                    ShareLink("Export…", item: model.marksAsMarkdown())
                    #endif
                }
                .padding(8)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Writing or changing the note on a highlight.
struct NoteEditor: View {
    @EnvironmentObject private var model: ReaderModel
    let mark: Highlight
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note").font(.headline)
            Text(mark.text)
                .font(.system(size: 12, design: .serif)).foregroundStyle(.secondary).lineLimit(4)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(HighlightColor.color(mark.color, dark: false).opacity(1)).frame(width: 3) }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .focused($focused)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(HierarchicalShapeStyle.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Remove Highlight", role: .destructive) { model.remove(mark); model.noteDraft = nil }
                Spacer()
                Button("Cancel") { model.noteDraft = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { model.saveNote(mark, text); model.noteDraft = nil }
                    .keyboardShortcut(.return, modifiers: .command)       // Return alone starts a new line in the note
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        #if os(macOS)
        .frame(width: 420)
        #endif
        .onAppear { text = mark.note ?? ""; focused = true }
    }
}
