import AppKit
import SwiftUI

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library.shared
    @StateObject private var model = ReaderModel.shared

    var body: some Scene {
        Window("Folio", id: "main") {
            RootView()
                .environmentObject(library)
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 1120, height: 780)
        .commands { FolioCommands(model: model) }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Folio", systemImage: "book.closed") {
            MenuBarMenu()
                .environmentObject(library)
                .environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: ReaderModel
    @EnvironmentObject private var library: Library
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.book != nil { ReaderView() } else { LibraryView() }
        }
        .overlay {
            if model.isLoading {
                ProgressView("Opening…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: Book.contentTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                var last: LibraryEntry?
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    if let e = await library.add(url) { last = e }
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                if urls.count == 1, let last { model.open(last) }
            }
        }
        .sheet(isPresented: $model.showStats) { StatsView().environmentObject(library) }
        .alert("Couldn’t open that book", isPresented: Binding(get: { model.errorMessage != nil },
                                                              set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background(WindowAccessor { model.register(mainWindow: $0) })
        .onAppear { model.openMain = { openWindow(id: "main") } }
    }
}

struct FolioCommands: Commands {
    @ObservedObject var model: ReaderModel
    @ObservedObject private var narrator = Narrator.shared
    @AppStorage(Keys.twoPages) private var twoPages = false
    @AppStorage(Keys.pagedTurns) private var pagedTurns = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Book…") { model.showMainWindow(); model.showImporter = true }
                .keyboardShortcut("o")
            Button("Find Free Books…") { model.closeBook(); model.showMainWindow(); model.showDiscover = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Book") { model.showMainWindowIfNeeded(); model.focusSearch() }
                .keyboardShortcut("f")
                .disabled(model.book == nil)
            Button("Find Next") { model.nextHit() }
                .keyboardShortcut("g")
                .disabled(model.hits.isEmpty)
            Button("Find Previous") { model.previousHit() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.hits.isEmpty)
        }
        CommandMenu("Book") {
            Button("Previous Chapter") { model.previousChapter() }
                .keyboardShortcut("[")
                .disabled(!model.hasPrevious)
            Button("Next Chapter") { model.nextChapter() }
                .keyboardShortcut("]")
                .disabled(!model.hasNext)
            Divider()
            Button(model.isBookmarked ? "Remove Bookmark" : "Add Bookmark") { model.toggleBookmark() }
                .keyboardShortcut("d")
                .disabled(model.book == nil)
            Button("Highlight Selection") { model.highlightSelection() }
                .keyboardShortcut("h", modifiers: [.command, .control])
                .disabled(model.book == nil)
            Button("Add Note to Selection…") { model.noteSelection() }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(model.book == nil)
            Button("Look Up Selection") { model.lookUpSelection() }
                .keyboardShortcut("l")
                .disabled(model.book == nil)
            Button("Export Highlights and Notes…") { model.exportMarks() }
                .disabled(model.entry?.marks.isEmpty ?? true)
            Divider()
            Button(narrator.speaking ? "Stop Reading Aloud" : "Read Aloud") { narrator.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.book == nil)
            Divider()
            Button("Next Page") { PageTurner.shared.turn(1) }.disabled(model.book == nil)
            Button("Previous Page") { PageTurner.shared.turn(-1) }.disabled(model.book == nil)
            Toggle("Turn Pages Instead of Scrolling", isOn: $pagedTurns)
            Divider()
            Button(model.showsOriginal ? "Show as Text" : "Show Original Pages") { model.toggleOriginal() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.canSwitchForm)
            Toggle("Two Pages Side by Side", isOn: $twoPages)
                .disabled(!model.showsOriginal)
            Button("Recognise Text on These Pages") { model.recogniseText() }
                .disabled(model.book?.pdf == nil || model.book?.pdf?.hasText == true || model.recognising != nil)
            Button(model.showsOriginal ? "Zoom In" : "Bigger Text") { model.adjustFontSize(1) }.keyboardShortcut("=")
            Button(model.showsOriginal ? "Zoom Out" : "Smaller Text") { model.adjustFontSize(-1) }.keyboardShortcut("-")
            Divider()
            Button(model.isFloating ? "Return to Window" : "Float Book") { model.toggleFloat() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.book == nil)
            Button("Back to Library") { model.closeBook() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.book == nil)
            Divider()
            Button("Reading Statistics") { model.showMainWindow(); model.showStats = true }
        }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject private var model: ReaderModel
    @EnvironmentObject private var library: Library
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let book = model.book {
            Text(book.title)
            Text("\(book.chapterTitles[min(model.chapter, book.chapterCount - 1)]) · \(Int((model.progress * 100).rounded()))%")
            Divider()
            Button(model.isFloating ? "Return to Window" : "Float Book") { remember(); model.toggleFloat() }
            Button("Next Chapter") { model.nextChapter() }.disabled(!model.hasNext)
            Button("Previous Chapter") { model.previousChapter() }.disabled(!model.hasPrevious)
            Divider()
        }
        let recent = library.recent(8)
        if !recent.isEmpty {
            Menu("Recent Books") {
                ForEach(recent) { e in
                    Button(e.title) {
                        remember()
                        model.open(e)
                        if !model.isFloating { model.showMainWindow() }
                    }
                }
            }
        }
        Button("Show Folio") { remember(); model.showMainWindow() }
        Button("Open Book…") { remember(); model.showMainWindow(); model.showImporter = true }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Folio") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func remember() { model.openMain = { openWindow(id: "main") } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SpaceWeather.shared.start()      // live Kp index for the aurora on the covers
        PageTurner.shared.start()
        ReadingLog.shared.start()
        ShelfSync.shared.start()
        Spotlight.catchUp()
        FinderCover.catchUp()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        Task {
            for url in urls.dropFirst() { await Library.shared.add(url) }
            ReaderModel.shared.open(url: first)
            if !ReaderModel.shared.isFloating { ReaderModel.shared.showMainWindow() }
        }
    }

    /// A book chosen from Spotlight's results.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let id = Spotlight.entryID(from: userActivity), let entry = Library.shared.entry(id) else { return false }
        ReaderModel.shared.open(entry)
        if !ReaderModel.shared.isFloating { ReaderModel.shared.showMainWindow() }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ReaderModel.shared.showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ReaderModel.shared.savePosition()
        ReadingLog.shared.save()
        Library.shared.save()
    }

    // Right-click on the Dock icon
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let model = ReaderModel.shared
        if model.book != nil {
            let float = NSMenuItem(title: model.isFloating ? "Return to Window" : "Float Book",
                                   action: #selector(toggleFloat), keyEquivalent: "")
            float.target = self
            menu.addItem(float)
            let next = NSMenuItem(title: "Next Chapter", action: #selector(nextChapter), keyEquivalent: "")
            next.target = self
            menu.addItem(next)
            menu.addItem(.separator())
        }
        for e in Library.shared.recent(6) {
            let item = NSMenuItem(title: e.title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.id.uuidString
            if e.id == model.entryID { item.state = .on }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleFloat() { ReaderModel.shared.toggleFloat() }
    @objc private func nextChapter() { ReaderModel.shared.nextChapter() }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s),
              let e = Library.shared.entry(id) else { return }
        ReaderModel.shared.open(e)
        if !ReaderModel.shared.isFloating { ReaderModel.shared.showMainWindow() }
    }
}
