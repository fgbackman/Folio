import AppKit
import CoreSpotlight
import SwiftUI

/// A cover as a still picture: what the shelf shows, without the moving sky. Used wherever a cover has
/// to leave the app — Spotlight results and the icons of book files in the Finder.
struct CoverStill: View {
    let title: String
    let author: String
    let sky: Int?

    var body: some View {
        let d = CoverDesignCache.shared.design(title: title, author: author, sky: sky)
        let p = d.palette
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Canvas { ctx, size in
                    d.drawStatic(&ctx, size: size)
                    d.drawStars(&ctx, size: size)
                }
                LinearGradient(stops: [
                    .init(color: p.dark ? CoverPalette.rgb(p.bottom, 0) : Color.white.opacity(0), location: 0.48),
                    .init(color: p.dark ? CoverPalette.rgb(p.bottom, 0.55) : Color.white.opacity(0.40), location: 0.8),
                    .init(color: p.dark ? CoverPalette.rgb(p.bottom, 0.40) : Color.white.opacity(0.24), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                VStack(spacing: w * 0.035) {
                    Rectangle().fill(CoverPalette.rgb(p.ink, 0.45)).frame(width: w * 0.12, height: max(0.5, w * 0.004))
                    Text(title)
                        .font(.system(size: w * 0.105, weight: .light, design: .serif))
                        .multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.5)
                        .foregroundStyle(CoverPalette.rgb(p.ink))
                    if !author.isEmpty {
                        Text(author.uppercased())
                            .font(.system(size: w * 0.042, design: .serif)).tracking(w * 0.012)
                            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                            .foregroundStyle(CoverPalette.rgb(p.ink, 0.72))
                    }
                }
                .padding(.horizontal, w * 0.09)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, w * 0.16)
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
    }

    @MainActor static func image(title: String, author: String, sky: Int?, width: CGFloat = 256) -> NSImage? {
        let renderer = ImageRenderer(content: CoverStill(title: title, author: author, sky: sky).frame(width: width, height: width * 1.5))
        renderer.scale = 2
        return renderer.nsImage
    }
}

extension CoverDesign {
    /// The stars and the lines of the figure, as still ink.
    func drawStars(_ ctx: inout GraphicsContext, size: CGSize) {
        guard size.width > 2 else { return }
        let p = CoverPainter(self, size)
        var lines = Path()
        for (a, b) in field.segs where a < field.stars.count && b < field.stars.count {
            lines.move(to: p.pt(field.stars[a].p))
            lines.addLine(to: p.pt(field.stars[b].p))
        }
        ctx.stroke(lines, with: .color(p.ink((1, 1, 1), 0.34)), lineWidth: max(0.5, size.width * 0.003))
        for s in field.stars {
            let c = p.pt(s.p)
            let r = max(0.35, p.starRadius(s.mag))
            if c.x < -r || c.y < -r || c.x > size.width + r || c.y > size.height + r { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(p.ink(s.rgb, 0.95)))
        }
    }
}

/// Books in the Mac's own search: typing a title, an author or words from the opening of a book into
/// Spotlight finds it, and choosing it opens it in Folio.
enum Spotlight {
    private static let domain = "com.fred.folio.books"
    private static let indexedKey = "spotlightIndexed.v1"

    @MainActor static func index(_ entry: LibraryEntry, text: String?) {
        guard CSSearchableIndex.isIndexingAvailable(), !Library.isTrial else { return }
        let attrs = CSSearchableItemAttributeSet(contentType: .content)
        attrs.title = entry.title
        attrs.displayName = entry.title
        if !entry.author.isEmpty { attrs.authorNames = [entry.author]; attrs.creator = entry.author }
        attrs.contentDescription = [entry.author, "\(entry.format) · \(entry.words.formatted()) words"].filter { !$0.isEmpty }.joined(separator: " · ")
        attrs.kind = "Book"
        attrs.keywords = entry.labels
        attrs.contentURL = entry.url
        if let text, !text.isEmpty { attrs.textContent = text }
        if let cover = CoverStill.image(title: entry.title, author: entry.author, sky: entry.sky, width: 128),
           let tiff = cover.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            attrs.thumbnailData = png
        }
        let item = CSSearchableItem(uniqueIdentifier: entry.id.uuidString, domainIdentifier: domain, attributeSet: attrs)
        item.expirationDate = .distantFuture
        let id = entry.id.uuidString
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error { NSLog("Folio: Spotlight would not index a book: \(error.localizedDescription)"); return }
            DispatchQueue.main.async {
                var done = Set(UserDefaults.standard.stringArray(forKey: indexedKey) ?? [])
                done.insert(id)
                UserDefaults.standard.set(Array(done), forKey: indexedKey)
            }
        }
    }

    static func remove(_ id: UUID) {
        guard !Library.isTrial else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id.uuidString], completionHandler: nil)
    }

    /// Indexes whatever on the shelf has not been indexed yet, a book at a time, without holding up the app.
    @MainActor static func catchUp() {
        guard !Library.isTrial else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: indexedKey) ?? [])
        // Books that left the shelf while Folio was not looking leave the index too.
        let gone = done.subtracting(Library.shared.entries.map(\.id.uuidString))
        if !gone.isEmpty {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: Array(gone), completionHandler: nil)
            done.subtract(gone)
            UserDefaults.standard.set(Array(done), forKey: indexedKey)
        }
        let waiting = Library.shared.entries.filter { !done.contains($0.id.uuidString) && $0.exists }
        guard !waiting.isEmpty else { return }
        Task {
            for entry in waiting {
                let url = entry.url
                let text = await Task.detached(priority: .utility) { (try? Book(url: url))?.sample(200_000) }.value
                if let now = Library.shared.entry(entry.id) { index(now, text: text) }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// The book a Spotlight result stands for.
    static func entryID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return UUID(uuidString: id)
    }
}

/// Gives the files of books Folio downloaded their Folio cover as an icon, so they are recognisable in the Finder.
/// Only files in Folio's own folder are touched; books kept elsewhere are left as they are.
enum FinderCover {
    /// Covers for the downloaded books that have none yet, a few at a time so launch is not held up.
    @MainActor static func catchUp() {
        let bare = Library.shared.entries.filter { $0.isOwned && $0.exists && getxattr($0.path, "com.apple.ResourceFork", nil, 0, 0, 0) <= 0 }
        guard !bare.isEmpty else { return }
        Task {
            for entry in bare {
                apply(to: entry)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    @MainActor static func apply(to entry: LibraryEntry) {
        guard entry.isOwned, entry.exists, UserDefaults.standard.object(forKey: Keys.finderCovers) as? Bool ?? true else { return }
        guard let cover = CoverStill.image(title: entry.title, author: entry.author, sky: entry.sky, width: 256) else { return }
        // An icon is square; the cover stands upright in the middle of it.
        let icon = NSImage(size: NSSize(width: 512, height: 512))
        icon.lockFocus()
        cover.draw(in: NSRect(x: 512 / 6, y: 0, width: 512 * 2 / 3, height: 512))
        icon.unlockFocus()
        let path = entry.path
        // Setting an icon rewrites the file's dates; the conversion of a PDF is filed under them, so they are put back.
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        NSWorkspace.shared.setIcon(icon, forFile: path, options: [])
        if let date = attrs?[.modificationDate] as? Date {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }
}
