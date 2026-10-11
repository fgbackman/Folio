import SwiftUI

@main
struct FolioMobileApp: App {
    @StateObject private var library = Library.shared
    @StateObject private var model = ReaderModel.shared
    @Environment(\.scenePhase) private var phase

    init() {
        SpaceWeather.shared.start()      // live Kp index for the aurora on the covers
        ReadingLog.shared.start()
        Task {
            await Shelf.sweep()
            #if DEBUG
            // For trying the app in the simulator, where nothing can be tapped from a script:
            //   simctl launch <device> com.fred.folio -debugOpen <part of a title> [-debugChapter n] [-debugShow contents|appearance]
            //   simctl launch <device> com.fred.folio -debugShow cover|discover|stats
            switch UserDefaults.standard.string(forKey: "debugShow") {
            case "cover": ReaderModel.shared.frontCover = Library.shared.entries.first
            case "discover": ReaderModel.shared.showDiscover = true
            case "stats": ReaderModel.shared.showStats = true
            default: break
            }
            if let wanted = UserDefaults.standard.string(forKey: "debugOpen"),
               let entry = Library.shared.entries.first(where: { $0.title.localizedCaseInsensitiveContains(wanted) }) {
                let chapter = UserDefaults.standard.integer(forKey: "debugChapter")
                ReaderModel.shared.open(entry, at: chapter > 0 ? (chapter: chapter, block: 0) : nil)
            }
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            MobileRoot()
                .environmentObject(library)
                .environmentObject(model)
                .onOpenURL { url in Task { if let entry = await Shelf.take(url) { model.open(entry) } } }
        }
        .onChange(of: phase) { _, now in
            guard now != .active else { Task { await Shelf.sweep() }; return }
            model.savePosition()
            ReadingLog.shared.save()
            library.save()
        }
    }
}

struct MobileRoot: View {
    @EnvironmentObject private var model: ReaderModel
    @EnvironmentObject private var library: Library
    @Environment(\.horizontalSizeClass) private var width

    var body: some View {
        Group {
            if model.book == nil {
                NavigationStack { LibraryView() }
            } else if width == .compact {
                PhoneReader()       // one column: the page, with the contents on a sheet
            } else {
                ReaderView()        // the Mac's layout: contents beside the page
            }
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
                for url in urls { if let e = await Shelf.take(url) { last = e } }
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
    }
}

enum Shelf {
    /// Shelves books left in Folio's folder in the Files app (On My iPhone › Folio), or put there from a Mac's Finder.
    private static let kinds: Set<String> = ["epub", "pdf", "txt", "text", "md", "markdown", "html", "htm", "xhtml", "fb2", "mobi", "azw", "azw3", "prc", "rtf"]

    @MainActor static func sweep() async {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) else { return }
        for file in files where kinds.contains(file.pathExtension.lowercased()) {
            if await take(file) != nil { try? fm.removeItem(at: file) }
        }
    }

    /// Copies a book chosen in Files, or sent from another app, into Folio's own folder and shelves it.
    /// The file outside can only be read while the system lends it, so the shelf keeps its own copy.
    @MainActor static func take(_ url: URL) async -> LibraryEntry? {
        let fm = FileManager.default
        let books = Library.home.appendingPathComponent("Books", isDirectory: true)
        try? fm.createDirectory(at: books, withIntermediateDirectories: true)
        if url.standardizedFileURL.path.hasPrefix(books.standardizedFileURL.path + "/") { return await Library.shared.add(url) }
        let lent = url.startAccessingSecurityScopedResource()
        defer { if lent { url.stopAccessingSecurityScopedResource() } }
        let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for n in 0..<50 {
            let dest = books.appendingPathComponent(n == 0 ? url.lastPathComponent : "\(base) \(n + 1).\(ext)")
            if fm.fileExists(atPath: dest.path) {
                // the same name and size: the book is already here
                if ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int ?? -2) == size { return await Library.shared.add(dest) }
                continue
            }
            do { try fm.copyItem(at: url, to: dest) } catch { return nil }
            return await Library.shared.add(dest)
        }
        return nil
    }
}
