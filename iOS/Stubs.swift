import SwiftUI

// Parts of the Mac app that have no counterpart here yet. The shelf calls them; they do nothing.

enum Spotlight {
    @MainActor static func index(_ entry: LibraryEntry, text: String?) {}
    static func remove(_ id: UUID) {}
}

enum FinderCover {
    @MainActor static func apply(to entry: LibraryEntry) {}
    @MainActor static func catchUp() {}
}

@MainActor
final class ShelfSync: ObservableObject {
    static let shared = ShelfSync()
    @Published private(set) var status = ""
    static var folder: URL? { nil }
    func syncSoon(after seconds: Double) {}
    func noteLocalChange() {}
    func noteRemoved(_ entry: LibraryEntry) {}
}

/// On the Mac this hands the scroll view to the page-turn keys; a finger does that here.
struct ScrollGrabber: View {
    let role: ReaderRole
    let overlap: CGFloat
    var body: some View { Color.clear }
}
