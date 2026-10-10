import AppKit
import SwiftUI

/// A borderless panel that is nothing but the page. It can become key so it scrolls
/// and takes keyboard shortcuts; Esc returns to the main window.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { ReaderModel.shared.exitFloat() }
    }
}

@MainActor
final class FloatController {
    static let shared = FloatController()
    private var panel: FloatingPanel?

    func show() {
        if panel == nil {
            let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
                                  styleMask: [.borderless, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.minSize = NSSize(width: 240, height: 200)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = false
            let host = NSHostingView(rootView: FloatingBookView()
                .environmentObject(ReaderModel.shared)
                .environmentObject(Library.shared))
            host.wantsLayer = true
            p.contentView = host
            if !p.setFrameUsingName("FolioFloatingBook") { p.center() }
            p.setFrameAutosaveName("FolioFloatingBook")
            panel = p
        }
        applyLevel()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.panel?.invalidateShadow()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func applyLevel() {
        let onTop = UserDefaults.standard.object(forKey: Keys.floatOnTop) as? Bool ?? true
        panel?.level = onTop ? .floating : .normal
    }
}

/// The floating book: page only. Controls fade in when the pointer reaches the top edge,
/// a resize grip appears in the bottom-right corner.
struct FloatingBookView: View {
    @EnvironmentObject private var model: ReaderModel
    @AppStorage(Keys.theme) private var themeName = Theme.paper.rawValue
    @AppStorage(Keys.floatTheme) private var floatThemeName = ""
    @AppStorage(Keys.floatOpacity) private var pageOpacity: Double = 1.0
    @AppStorage(Keys.floatOnTop) private var onTop = true

    @State private var showBar = false
    @State private var showGrip = false

    private var theme: Theme { Theme(rawValue: floatThemeName) ?? Theme(rawValue: themeName) ?? .paper }

    var body: some View {
        let theme = self.theme
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ThemeBackground(theme: theme).opacity(pageOpacity)

                if model.book != nil {
                    BookTextView(role: .float)
                } else {
                    Text("No book open").foregroundStyle(theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Invisible strip along the top for dragging the window.
                WindowDragArea().frame(height: 22).frame(maxWidth: .infinity)

                if showBar {
                    controlBar(theme: theme).transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    WindowResizeGrip()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                        .opacity(showGrip ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .frame(width: 22, height: 22)
                .padding(3)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let bar = p.y < 46
                    let grip = p.x > geo.size.width - 46 && p.y > geo.size.height - 46
                    if bar != showBar { withAnimation(.easeOut(duration: 0.15)) { showBar = bar } }
                    if grip != showGrip { withAnimation(.easeOut(duration: 0.15)) { showGrip = grip } }
                case .ended:
                    withAnimation(.easeOut(duration: 0.25)) { showBar = false; showGrip = false }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .colorSchemeOverride(theme.colorScheme)
        // Esc: NSHostingView can consume cancelOperation(_:) before it reaches the panel.
        .onExitCommand { model.exitFloat() }
        .onChange(of: onTop) { _, _ in FloatController.shared.applyLevel() }
    }

    private func controlBar(theme: Theme) -> some View {
        HStack(spacing: 12) {
            barButton("xmark", help: "Back to window (Esc)") { model.exitFloat() }
            barButton("chevron.left", help: "Previous chapter") { model.previousChapter() }.disabled(!model.hasPrevious)
            Spacer(minLength: 4)
            if let book = model.book {
                Text(book.chapterTitles[min(model.chapter, book.chapterCount - 1)])
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(theme.secondary)
                    .allowsHitTesting(false)
            }
            Text("\(Int((model.progress * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.secondary)
                .allowsHitTesting(false)
            Spacer(minLength: 4)
            barButton("textformat.size.smaller", help: "Smaller text") { model.adjustFontSize(-1) }
            barButton("textformat.size.larger", help: "Larger text") { model.adjustFontSize(1) }
            barButton(onTop ? "pin.fill" : "pin", help: onTop ? "Stop floating above other windows" : "Keep above other windows") { onTop.toggle() }
            barButton("chevron.right", help: "Next chapter") { model.nextChapter() }.disabled(!model.hasNext)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                VisualEffectView(material: .hudWindow)
                WindowDragArea()
            }
        }
        .foregroundStyle(theme.text)
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Dragging and resizing a borderless window

final class DragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override var mouseDownCanMoveWindow: Bool { true }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

final class ResizeGripView: NSView {
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let p = NSEvent.mouseLocation
        var f = startFrame
        f.size.width = max(w.minSize.width, startFrame.width + (p.x - startMouse.x))
        f.size.height = max(w.minSize.height, startFrame.height - (p.y - startMouse.y))
        f.origin.y = startFrame.maxY - f.size.height     // keep the top edge fixed
        w.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) { window?.invalidateShadow() }
    override var mouseDownCanMoveWindow: Bool { false }
}

struct WindowResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeGripView { ResizeGripView() }
    func updateNSView(_ nsView: ResizeGripView, context: Context) {}
}
