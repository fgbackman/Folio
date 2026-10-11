import AppKit
import SwiftUI

/// Turning pages from the keyboard: Space, the arrow keys and Page Up/Down move the text a screenful at a
/// time, and carry on into the next chapter at the end of this one.
@MainActor
final class PageTurner {
    static let shared = PageTurner()

    private var scrollViews: [ReaderRole: () -> NSScrollView?] = [:]
    private var overlaps: [ReaderRole: CGFloat] = [:]
    private var monitor: Any?

    func register(_ role: ReaderRole, overlap: CGFloat, _ find: @escaping () -> NSScrollView?) {
        scrollViews[role] = find
        overlaps[role] = overlap
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let window = event.window
            let key = event.keyCode, flags = event.modifierFlags
            let taken = MainActor.assumeIsolated { PageTurner.shared.handle(key, flags, in: window) }
            return taken ? nil : event
        }
    }

    private func handle(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow?) -> Bool {
        let model = ReaderModel.shared
        guard model.book != nil, let window, window.attachedSheet == nil,
              window === model.mainWindow || window is FloatingPanel else { return false }
        let mods = flags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        // typing in the search field, or in a note
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        let back = flags.contains(.shift)
        switch keyCode {
        case 49: turn(back ? -1 : 1)        // space
        case 124, 121: turn(1)              // right arrow, page down
        case 123, 116: turn(-1)             // left arrow, page up
        default: return false
        }
        return true
    }

    func turn(_ way: Int) {
        let model = ReaderModel.shared
        guard model.book != nil else { return }
        if model.showsOriginal {
            NotificationCenter.default.post(name: .folioPageTurn, object: way)
            return
        }
        let role: ReaderRole = model.isFloating ? .float : .window
        guard let scroll = scrollViews[role]?(), let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        let visible = clip.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        let top = -scroll.contentInsets.top
        let bottom = max(top, doc.frame.height - clip.bounds.height + scroll.contentInsets.bottom)
        let y = clip.bounds.origin.y
        if way > 0, y >= bottom - 2 {
            if model.hasNext { model.nextChapter() }
            return
        }
        if way < 0, y <= top + 2 {
            if model.hasPrevious, let book = model.book {
                let last = max(0, book.blocks(model.chapter - 1).count - 1)
                model.go(chapter: model.chapter - 1, block: last, anchor: .bottom)
            }
            return
        }
        let step = max(40, visible - (overlaps[role] ?? 30))
        let target = NSPoint(x: clip.bounds.origin.x, y: min(bottom, max(top, y + CGFloat(way) * step)))
        // Sent as turns of a scroll wheel, the one kind of scrolling the page keeps track of its place through.
        let distance = target.y - y
        let paged = UserDefaults.standard.bool(forKey: Keys.pagedTurns)
        let steps = paged ? 1 : 12
        glide?.invalidate()
        var sent = 0, moved = 0.0
        func send() {
            sent += 1
            let t = Double(sent) / Double(steps)
            let want = Double(distance) * (1 - pow(1 - t, 3))
            let delta = Int32((want - moved).rounded())
            moved += Double(delta)
            if delta != 0, let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0),
               let event = NSEvent(cgEvent: cg) {
                scroll.scrollWheel(with: event)
            }
        }
        send()
        guard steps > 1 else { return }
        glide = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                send()
                if sent >= steps { timer.invalidate() }
            }
        }
    }

    private var glide: Timer?
}

/// Sits behind the text and hands the scroll view it lives in to the page turner.
struct ScrollGrabber: NSViewRepresentable {
    let role: ReaderRole
    let overlap: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let role = self.role
        PageTurner.shared.register(role, overlap: overlap) { [weak view] in view?.enclosingScrollView }
    }
}
