import AppKit
import Charts
import SwiftUI

/// How much has been read, day by day. The clock runs while a book is open, Folio is in front (or reading
/// aloud) and the page has moved in the last couple of minutes.
@MainActor
final class ReadingLog: ObservableObject {
    static let shared = ReadingLog()

    struct Day: Codable { var seconds: Double = 0; var words: Double = 0 }

    @Published private(set) var days: [String: Day] = [:]

    private let file = Library.home.appendingPathComponent("reading.json")
    private var timer: Timer?
    private var lastProgress: (id: UUID, value: Double)?
    private static let tick = 10.0

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Day].self, from: data) { days = saved }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: ReadingLog.tick, repeats: true) { _ in
            MainActor.assumeIsolated { ReadingLog.shared.beat() }
        }
    }

    static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func beat() {
        let model = ReaderModel.shared
        guard let id = model.entryID, let book = model.book else { lastProgress = nil; return }
        let aloud = Narrator.shared.speaking
        guard aloud || (NSApp.isActive && Date().timeIntervalSince(model.lastActivity) < 150) else { return }
        // Words that went by since the last beat. A leap through the book is a jump, not reading.
        var words = 0.0
        if let last = lastProgress, last.id == id {
            let moved = model.progress - last.value
            if moved > 0, moved * Double(book.wordCount) < 400 * ReadingLog.tick / 60 * 3 { words = moved * Double(book.wordCount) }
        }
        lastProgress = (id, model.progress)
        days[ReadingLog.key(Date()), default: Day()].seconds += ReadingLog.tick
        days[ReadingLog.key(Date()), default: Day()].words += words
        Library.shared.addReading(id, seconds: ReadingLog.tick, words: words)
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: file, options: .atomic) }
    }

    /// The last `n` days, oldest first.
    func recent(_ n: Int) -> [(date: Date, day: Day)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (d, days[ReadingLog.key(d)] ?? Day())
        }
    }

    /// Days in a row with at least a minute of reading, ending today (or yesterday, if today has not begun).
    var streak: Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        func read(_ d: Date) -> Bool { (days[ReadingLog.key(d)]?.seconds ?? 0) >= 60 }
        if !read(day) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        var n = 0
        while read(day), n < 5000 {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return n
    }

    var total: Day {
        days.values.reduce(into: Day()) { $0.seconds += $1.seconds; $0.words += $1.words }
    }
}

struct StatsView: View {
    @EnvironmentObject private var library: Library
    @ObservedObject private var log = ReadingLog.shared
    @Environment(\.dismiss) private var dismiss

    static func time(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }

    var body: some View {
        let recent = log.recent(14)
        let today = recent.last?.day ?? .init()
        let week = recent.suffix(7).reduce(0) { $0 + $1.day.seconds }
        let total = log.total
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Reading").font(.system(size: 22, weight: .bold, design: .serif))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        figure("Today", StatsView.time(today.seconds))
                        figure("This week", StatsView.time(week))
                        figure("Streak", "\(log.streak) day\(log.streak == 1 ? "" : "s")")
                        figure("All time", StatsView.time(total.seconds))
                        figure("Pace", total.seconds >= 300 && total.words > 0 ? "\(Int(total.words / (total.seconds / 60))) wpm" : "—")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LAST TWO WEEKS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                        Chart(recent, id: \.date) { item in
                            BarMark(x: .value("Day", item.date, unit: .day), y: .value("Minutes", item.day.seconds / 60))
                                .cornerRadius(3)
                        }
                        .chartYAxisLabel("minutes")
                        .frame(height: 170)
                    }
                    let books = library.entries.filter { ($0.seconds ?? 0) >= 60 }.sorted { ($0.seconds ?? 0) > ($1.seconds ?? 0) }
                    if !books.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("BY BOOK").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                            ForEach(books.prefix(20)) { e in
                                let seconds = e.seconds ?? 0, words = e.readWords ?? 0
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.title).lineLimit(1)
                                        if !e.author.isEmpty { Text(e.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if seconds >= 600, words > 0 {
                                        let pace = words / (seconds / 60)
                                        Text("\(Int(pace)) wpm").foregroundStyle(.secondary).monospacedDigit()
                                        let left = Double(e.words) * (1 - e.progress) / max(60, pace) * 60
                                        if e.progress < 0.985 { Text("· \(StatsView.time(left)) left").foregroundStyle(.secondary).monospacedDigit() }
                                    }
                                    Text(StatsView.time(seconds)).monospacedDigit().frame(minWidth: 80, alignment: .trailing)
                                }
                                .font(.system(size: 13))
                                Divider()
                            }
                        }
                    }
                    Text("The clock runs while a book is open in front of you and the page is moving, or while it is read aloud.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 560)
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(HierarchicalShapeStyle.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
