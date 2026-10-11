#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import PDFKit
import SwiftUI

/// The covers the books came with: the picture an EPUB names as its cover, or a PDF's first page.
/// Each is found once, scaled down and kept in Folio's folder; a book without one keeps its sky.
@MainActor
final class OwnCovers: ObservableObject {
    static let shared = OwnCovers()

    @Published private var images: [UUID: NSImage] = [:]
    private var asked: Set<UUID> = []

    private nonisolated static let folder: URL = {
        let url = Library.home.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The book's own cover if it has one and it has been found; asking starts the search.
    func image(for entry: LibraryEntry) -> NSImage? {
        if let img = images[entry.id] { return img }
        guard !asked.contains(entry.id), entry.exists else { return nil }
        asked.insert(entry.id)
        let id = entry.id, url = entry.url
        Task {
            let found = await Task.detached(priority: .utility) { OwnCovers.load(id, url) }.value
            if let found { images[id] = found }
        }
        return nil
    }

    private nonisolated static func load(_ id: UUID, _ url: URL) -> NSImage? {
        let fm = FileManager.default
        let kept = folder.appendingPathComponent(id.uuidString + ".jpg"), none = folder.appendingPathComponent(id.uuidString + ".none")
        if let data = try? Data(contentsOf: kept), let img = NSImage(data: data) { return img }
        if fm.fileExists(atPath: none.path) { return nil }
        guard let cg = find(url), let small = scaled(cg, longest: 720) else {
            fm.createFile(atPath: none.path, contents: nil)
            return nil
        }
        try? small.encoded("public.jpeg", quality: 0.85)?.write(to: kept, options: .atomic)
        return picture(small)
    }

    private nonisolated static func find(_ url: URL) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        var pages: URL?
        if ext == "pdf" { pages = url } else if Converted.comics.contains(ext) { pages = try? Converted.comic(url) }
        if let pages {
            guard let page = PDFDocument(url: pages)?.page(at: 0) else { return nil }
            let box = page.bounds(for: .cropBox)
            guard box.width > 1, box.height > 1 else { return nil }
            let k = 720 / max(box.width, box.height)
            let thumb = page.thumbnail(of: CGSize(width: box.width * k, height: box.height * k), for: .cropBox)
            return bitmap(thumb)
        }
        guard let book = try? Book(url: url), let data = book.coverData(), let img = NSImage(data: data) else { return nil }
        return bitmap(img)
    }

    private nonisolated static func bitmap(_ image: NSImage) -> CGImage? {
        #if os(macOS)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    private nonisolated static func picture(_ image: CGImage) -> NSImage {
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #else
        return UIImage(cgImage: image)
        #endif
    }

    private nonisolated static func scaled(_ image: CGImage, longest: CGFloat) -> CGImage? {
        let k = min(1, longest / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * k)), h = max(1, Int(CGFloat(image.height) * k))
        guard w >= 40, h >= 40,     // a publisher's mark or a spacer, not a cover
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// A book's cover on the shelf: its own when those are asked for and it has one, otherwise its sky.
struct ShelfCover: View {
    let entry: LibraryEntry
    var animated = true
    @AppStorage(Keys.ownCovers) private var ownCovers = false
    @ObservedObject private var covers = OwnCovers.shared

    var body: some View {
        if ownCovers, let image = covers.image(for: entry) {
            Color(white: 0.92)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill) }
                .clipped()
        } else {
            EtherealCover(title: entry.title, author: entry.author, sky: entry.sky, progress: entry.progress,
                          bookmarks: entry.bookmarks.count, animated: animated)
        }
    }
}
