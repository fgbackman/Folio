import SwiftUI

/// Searching the open libraries and fetching books from them.
@MainActor
final class Discover: ObservableObject {
    static let shared = Discover()

    enum Progress: Equatable {
        case waiting                // in the queue, behind other downloads
        case fetching(Double)       // 0…1, or below zero while the size is unknown
        case failed(String)
    }
    enum SourceState: Equatable { case idle, searching, found(Int), failed(String) }

    @Published var query = ""
    @Published private(set) var results: [OpenBook] = []
    @Published private(set) var states: [OpenSource: SourceState] = [:]
    @Published private(set) var progress: [String: Progress] = [:]
    @Published private(set) var searched = ""
    @Published var enabled: Set<OpenSource> {
        didSet { UserDefaults.standard.set(enabled.map(\.rawValue).sorted(), forKey: "openLibraries") }
    }

    private var bySource: [OpenSource: [OpenBook]] = [:]
    private var task: Task<Void, Never>?
    /// Downloads wait their turn: a few at a time, the rest in line.
    private var queue: [OpenBook] = []
    private var running: [String: Task<Void, Never>] = [:]
    private static let atOnce = 3
    /// What the results are of: a search, or a shelf being browsed.
    @Published private(set) var browsing: String?

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "openLibraries") {
            enabled = Set(saved.compactMap(OpenSource.init(rawValue:)))
        } else {
            enabled = Set(OpenSource.allCases)
        }
    }

    var searching: Bool { states.values.contains(.searching) }

    /// Asks every chosen library at once; results appear as each answers.
    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        browsing = nil
        ask(q, OpenSource.allCases.filter(enabled.contains)) { try await OpenLibraries.search($0, q) }
    }

    /// The most downloaded books of a subject (or of everything), from the libraries that keep such lists.
    func browse(_ subject: String?) {
        query = ""
        browsing = subject ?? "Popular"
        ask(subject ?? "Popular", OpenLibraries.browsable.filter(enabled.contains)) { try await OpenLibraries.browse($0, subject: subject) }
    }

    private func ask(_ q: String, _ sources: [OpenSource], _ fetch: @escaping @Sendable (OpenSource) async throws -> [OpenBook]) {
        task?.cancel()
        searched = q
        bySource = [:]
        results = []
        states = [:]
        for s in sources { states[s] = .searching }
        task = Task {
            await withTaskGroup(of: (OpenSource, Result<[OpenBook], Error>).self) { group in
                for s in sources {
                    group.addTask { (s, await Result { try await fetch(s) }) }
                }
                for await (source, result) in group {
                    if Task.isCancelled { return }
                    switch result {
                    case .success(let books):
                        bySource[source] = books
                        states[source] = .found(books.count)
                    case .failure(let error):
                        states[source] = .failed((error as? URLError)?.code == .timedOut ? "No answer" : error.localizedDescription)
                    }
                    merge()
                }
            }
        }
    }

    /// One from each library in turn, so no single library crowds out the rest.
    private func merge() {
        var out: [OpenBook] = []
        var seen = Set<String>()
        let lists = OpenSource.allCases.compactMap { bySource[$0] }
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count {
                // the Open Library and the Internet Archive often offer the very same scan
                if case .archive(let ids) = list[i].fetch, let first = ids.first, !seen.insert(first).inserted { continue }
                out.append(list[i])
            }
        }
        results = out
    }

    /// Puts a book in line to be downloaded and shelved.
    func get(_ book: OpenBook) {
        switch progress[book.id] {
        case .waiting, .fetching: return
        default: break
        }
        progress[book.id] = .waiting
        queue.append(book)
        pump()
    }

    /// Stops a download, or takes a book out of the line.
    func cancel(_ book: OpenBook) {
        queue.removeAll { $0.id == book.id }
        running[book.id]?.cancel()
        progress[book.id] = nil
    }

    var downloading: Int { running.count + queue.count }

    private func pump() {
        while running.count < Discover.atOnce, !queue.isEmpty {
            let book = queue.removeFirst()
            progress[book.id] = .fetching(-1)
            running[book.id] = Task {
                await fetch(book)
                running[book.id] = nil
                pump()
            }
        }
    }

    private func fetch(_ book: OpenBook) async {
        do {
            let id = book.id
            let url = try await OpenLibraries.download(book) { fraction in
                Task { @MainActor in
                    if case .fetching = Discover.shared.progress[id] { Discover.shared.progress[id] = .fetching(fraction) }
                }
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: url)
                progress[book.id] = nil
                return
            }
            guard await Library.shared.add(url) != nil else {
                try? FileManager.default.removeItem(at: url)
                progress[book.id] = .failed("Folio couldn’t read the file.")
                return
            }
            progress[book.id] = nil
        } catch {
            let stopped = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            progress[book.id] = stopped ? nil : .failed(error.localizedDescription)
        }
    }
}

private extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var model: ReaderModel
    @ObservedObject private var discover = Discover.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Find Free Books").font(.system(size: 22, weight: .bold, design: .serif))
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Title, author or subject", text: $discover.query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { discover.search() }
                    if discover.searching { ProgressView().controlSize(.small) }
                    Button("Search") { discover.search() }
                        .disabled(discover.query.trimmingCharacters(in: .whitespaces).isEmpty || discover.enabled.isEmpty)
                }
                .padding(8)
                .background(HierarchicalShapeStyle.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                sources
                subjects
            }
            .padding(20)
            Divider()
            results
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 640)
        .onAppear { focused = true }
    }

    private var sources: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OpenSource.allCases) { source in
                    let on = discover.enabled.contains(source)
                    Button {
                        if on { discover.enabled.remove(source) } else { discover.enabled.insert(source) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            Text(source.name)
                            switch discover.states[source] ?? .idle {
                            case .found(let n): Text("\(n)").foregroundStyle(.secondary)
                            case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            default: EmptyView()
                            }
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(help(source))
                }
            }
        }
    }

    /// Shelves to browse without searching: the most downloaded books of each subject.
    private var subjects: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Browse").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(["Popular"] + OpenLibraries.subjects, id: \.self) { name in
                    let on = discover.browsing == name
                    Button { discover.browse(name == "Popular" ? nil : name) } label: {
                        Text(name).font(.system(size: 12))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func help(_ source: OpenSource) -> String {
        if case .failed(let why) = discover.states[source] ?? .idle { return "\(source.name): \(why)" }
        return source.about
    }

    @ViewBuilder private var results: some View {
        if discover.results.isEmpty {
            VStack(spacing: 8) {
                if discover.searching {
                    ProgressView()
                    Text("Asking the libraries…").foregroundStyle(.secondary)
                } else if discover.searched.isEmpty {
                    Image(systemName: "globe").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Search \(discover.enabled.count == OpenSource.allCases.count ? "every open library" : "the chosen libraries") at once, or browse a subject.")
                    Text("Books you get are kept in Folio and appear on your shelf with a cover of their own.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if discover.browsing != nil {
                    Text("Nothing to browse under “\(discover.searched)” in the chosen libraries.").foregroundStyle(.secondary)
                } else {
                    Text("Nothing found for “\(discover.searched)”.").foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(discover.results) { book in
                        OpenBookRow(book: book) { dismiss() }
                        Divider().padding(.leading, 86)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private extension OpenBookRow {
    var cancelButton: some View {
        Button { discover.cancel(book) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .help("Stop this download")
    }
}

private struct OpenBookRow: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var model: ReaderModel
    @ObservedObject private var discover = Discover.shared
    let book: OpenBook
    let close: () -> Void

    /// The book's place on the shelf, once it has been fetched.
    private var entry: LibraryEntry? {
        guard let url = OpenLibraries.saved(book) else { return nil }
        return library.entry(forPath: url.standardizedFileURL.path)
    }

    var body: some View {
        let entry = self.entry
        HStack(alignment: .center, spacing: 14) {
            // The cover it has, or will have, on the shelf
            EtherealCover(title: entry?.title ?? book.title, author: entry?.author ?? book.author,
                          sky: entry?.sky ?? library.freeSky(title: book.title, author: book.author), animated: false)
                .frame(width: 52)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.system(size: 14, weight: .semibold, design: .serif)).lineLimit(2)
                if !book.author.isEmpty { Text(book.author).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Text("\(book.source.name) · \(book.detail)").font(.system(size: 11)).foregroundStyle(.tertiary)
                if case .failed(let why) = discover.progress[book.id] {
                    Label(why, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            action(entry)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    @ViewBuilder private func action(_ entry: LibraryEntry?) -> some View {
        if let entry {
            Button("Read") { model.open(entry); close() }.buttonStyle(.borderedProminent)
        } else if case .fetching(let fraction) = discover.progress[book.id] {
            HStack(spacing: 6) {
                if fraction >= 0 {
                    ProgressView(value: min(1, fraction)).frame(width: 70)
                } else {
                    ProgressView().controlSize(.small).frame(width: 70)
                }
                cancelButton
            }
        } else if case .waiting = discover.progress[book.id] {
            HStack(spacing: 6) {
                Text("Waiting").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 70)
                cancelButton
            }
        } else {
            Button("Get") { discover.get(book) }
                .help("Download from \(book.source.name) and add to your shelf")
        }
    }
}
