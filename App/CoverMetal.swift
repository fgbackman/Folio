import AppKit
import CoreVideo
import IOSurface
import Metal
import QuartzCore
import SwiftUI

// Draws the moving sky of every visible cover on the GPU. One display link drives them all; each
// frame the CPU lays out a short list of shapes per cover (CoverScene) and the shaders do the rest.
//
// All the covers are drawn in a single pass into one shared surface, side by side, and each cover's
// layer shows its own part of it. (Giving every cover a Metal layer of its own costs a trip to the
// window server per cover per frame, which is as slow as what this replaced.)
// When nothing is moving, nothing is drawn.

final class CoverRenderer {
    static let shared = CoverRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var starBuffers: [Int: (buffer: MTLBuffer, count: Int)] = [:]
    private let views = NSHashTable<CoverSkyView>.weakObjects()
    private var link: CADisplayLink?
    private let scene = CoverScene()

    /// Shape data for one frame, in chunks that are reused from frame to frame.
    final class Arena {
        var chunks: [MTLBuffer] = []
        var chunk = 0
        var used = 0
    }

    /// The shared surface. Three take turns: one on screen, one being drawn, one spare.
    private struct Sheet {
        let surface: IOSurfaceRef
        let texture: MTLTexture
        let arena = Arena()
    }
    private var sheets: [Sheet] = []
    private var sheetSize = (width: 0, height: 0)
    private var frame = 0
    private var busy = false
    private var shown = Set<ObjectIdentifier>()
    private static let chunkSize = 1 << 20
    private static let sheetWidth = 4096
    private static let gutter = 2
    private static let calm = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
    private static let lively = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: CoverShaders.source, options: nil) else { return nil }
        self.device = device
        self.queue = queue
        for name in ["prim", "mesh", "star", "moon"] {
            for blend in [CoverBlend.normal, .screen] {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = library.makeFunction(name: name + "_vertex")
                desc.fragmentFunction = library.makeFunction(name: name + "_fragment")
                let color = desc.colorAttachments[0]!
                color.pixelFormat = .bgra8Unorm
                color.isBlendingEnabled = true
                // colours arrive premultiplied; "screen" is 1 − (1 − src)(1 − dst) on every channel
                color.sourceRGBBlendFactor = blend == .screen ? .oneMinusDestinationColor : .one
                color.sourceAlphaBlendFactor = blend == .screen ? .oneMinusDestinationAlpha : .one
                color.destinationRGBBlendFactor = blend == .screen ? .one : .oneMinusSourceAlpha
                color.destinationAlphaBlendFactor = blend == .screen ? .one : .oneMinusSourceAlpha
                guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
                pipelines[CoverRenderer.key(name, blend)] = state
            }
        }
    }

    private static func key(_ name: String, _ blend: CoverBlend) -> String { name + (blend == .screen ? "+" : "") }

    // MARK: Scheduling

    func add(_ view: CoverSkyView) {
        views.add(view)
        wake()
    }

    func remove(_ view: CoverSkyView) {
        views.remove(view)
        wake()
    }

    /// Something changed: look again at the next screen refresh.
    func wake() {
        if link == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
            let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CoverRenderer.calm
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !busy else { return }
        let now = Date().timeIntervalSince(CoverClock.start)
        let visible = views.allObjects.filter { $0.isShowing }
        let ids = Set(visible.map { ObjectIdentifier($0) })
        // Every visible cover is redrawn when any of them moves, or when different covers come into view.
        guard ids != shown || visible.contains(where: { $0.wantsFrame(now) }) else {
            link.isPaused = true            // nothing is moving; wake() starts it again
            return
        }
        // the sky drifts slowly; only the lens under the pointer needs the full frame rate
        let rate = visible.contains(where: { $0.hoverBox?.info(now) != nil }) ? CoverRenderer.lively : CoverRenderer.calm
        if link.preferredFrameRateRange != rate { link.preferredFrameRateRange = rate }
        draw(visible, ids: ids, now: now)
    }

    // MARK: Drawing

    private struct Slot {
        let view: CoverSkyView
        let size: CGSize            // points
        let scale: Double
        var x = 0, y = 0            // pixels, in the sheet
        let width: Int, height: Int
    }

    /// Finds each cover a place on the sheet, in rows.
    private func arrange(_ visible: [CoverSkyView]) -> (slots: [Slot], height: Int) {
        var slots: [Slot] = []
        var x = 0, y = 0, rowHeight = 0
        let gutter = CoverRenderer.gutter
        for view in visible {
            let size = view.bounds.size
            let scale = Double(view.window?.backingScaleFactor ?? 2)
            let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
            guard w >= 1, h >= 1, w + 2 * gutter <= CoverRenderer.sheetWidth, h <= 8192 else { continue }
            if x + w + 2 * gutter > CoverRenderer.sheetWidth {
                x = 0
                y += rowHeight + gutter
                rowHeight = 0
            }
            slots.append(Slot(view: view, size: size, scale: scale, x: x + gutter, y: y + gutter, width: w, height: h))
            x += w + gutter
            rowHeight = max(rowHeight, h + gutter)
        }
        return (slots, y + rowHeight + gutter)
    }

    private func makeSheets(height: Int) -> Bool {
        let width = CoverRenderer.sheetWidth
        let height = (height + 511) & ~511
        if !sheets.isEmpty && sheetSize.height >= height { return true }
        guard height <= 16384 else { return false }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .shared
        var made: [Sheet] = []
        for _ in 0..<3 {
            let properties: [CFString: Any] = [kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                                               kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
            guard let surface = IOSurfaceCreate(properties as CFDictionary),
                  let texture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else { return false }
            if let srgb = CGColorSpace(name: CGColorSpace.sRGB), let plist = srgb.copyPropertyList() {
                IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist)
            }
            made.append(Sheet(surface: surface, texture: texture))
        }
        sheets = made
        sheetSize = (width, height)
        return true
    }

    private func draw(_ visible: [CoverSkyView], ids: Set<ObjectIdentifier>, now: Double) {
        // covers that have scrolled out of sight give up their place on the sheet
        for view in views.allObjects where !ids.contains(ObjectIdentifier(view)) { view.show(nil, .zero) }
        shown = ids
        let (slots, height) = arrange(visible)
        guard !slots.isEmpty, makeSheets(height: height), let commands = queue.makeCommandBuffer() else { return }
        frame = (frame + 1) % sheets.count
        let sheet = sheets[frame]
        sheet.arena.chunk = 0
        sheet.arena.used = 0

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sheet.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let sky = SkyNow.current
        let kp = SpaceWeather.shared.kp
        for slot in slots {
            let view = slot.view
            guard let design = view.design else { continue }
            encoder.setViewport(MTLViewport(originX: Double(slot.x), originY: Double(slot.y), width: Double(slot.width),
                                            height: Double(slot.height), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: slot.x, y: slot.y, width: slot.width, height: slot.height))
            design.compose(into: scene, size: slot.size, scale: slot.scale, t: view.moving ? now : 0, sky: sky, kp: kp,
                           progress: view.progress, bookmarks: view.bookmarks, hover: view.hoverBox?.info(now))
            encode(scene, field: design.field, arena: sheet.arena, encoder: encoder)
            view.drew()
        }
        encoder.endEncoding()

        // once the GPU has finished, point each cover's layer at its part of the new sheet
        busy = true
        let (sheetWidth, sheetHeight) = (Double(sheetSize.width), Double(sheetSize.height))
        commands.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for slot in slots where self.shown.contains(ObjectIdentifier(slot.view)) {
                    // a layer's contents are measured from the bottom, the sheet from the top
                    slot.view.show(sheet.surface, CGRect(x: Double(slot.x) / sheetWidth, y: 1 - Double(slot.y + slot.height) / sheetHeight,
                                                         width: Double(slot.width) / sheetWidth, height: Double(slot.height) / sheetHeight))
                }
                CATransaction.commit()
            }
        }
        commands.commit()
    }

    private func allocate(_ arena: Arena, _ bytes: Int) -> (MTLBuffer, Int)? {
        let size = (bytes + 255) & ~255
        if size > CoverRenderer.chunkSize { return device.makeBuffer(length: size, options: .storageModeShared).map { ($0, 0) } }
        if arena.used + size > CoverRenderer.chunkSize {
            arena.chunk += 1
            arena.used = 0
        }
        while arena.chunks.count <= arena.chunk {
            guard let b = device.makeBuffer(length: CoverRenderer.chunkSize, options: .storageModeShared) else { return nil }
            arena.chunks.append(b)
        }
        let offset = arena.used
        arena.used += size
        return (arena.chunks[arena.chunk], offset)
    }

    /// The constellation's stars, loaded into graphics memory once.
    private func stars(_ field: SkyField) -> (buffer: MTLBuffer, count: Int)? {
        if let s = starBuffers[field.index] { return s }
        // brightest first, so faint stars are drawn over the glows of bright ones
        let sorted = field.stars.sorted { $0.mag < $1.mag }
        let data = sorted.map { s in
            CoverStar(s0: V4(Float(s.p.x), Float(s.p.y), Float(s.mag), Float(s.parallax)),
                      s1: V4(Float(s.rgb.0), Float(s.rgb.1), Float(s.rgb.2), Float(s.variable)),
                      s2: V4(Float(s.twinklePeriod), Float(s.twinklePhase), 0, 0))
        }
        guard !data.isEmpty,
              let buffer = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<CoverStar>.stride,
                                             options: .storageModeShared) else { return nil }
        starBuffers[field.index] = (buffer, data.count)
        return (buffer, data.count)
    }

    /// Turns a composed scene into draw calls, in the order it was laid out.
    func encode(_ scene: CoverScene, field: SkyField, arena: Arena, encoder: MTLRenderCommandEncoder) {
        var uniforms = scene.uniforms
        let uniformSize = MemoryLayout<CoverUniforms>.stride
        func bind(_ u: inout CoverUniforms) {
            encoder.setVertexBytes(&u, length: uniformSize, index: 1)
            encoder.setFragmentBytes(&u, length: uniformSize, index: 1)
        }

        var primBuffer: (MTLBuffer, Int)?
        if !scene.prims.isEmpty, let slot = allocate(arena, scene.prims.count * MemoryLayout<CoverPrim>.stride) {
            scene.prims.withUnsafeBytes { slot.0.contents().advanced(by: slot.1).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            primBuffer = slot
        }
        var meshBuffer: (MTLBuffer, Int)?
        if !scene.verts.isEmpty, let slot = allocate(arena, scene.verts.count * MemoryLayout<CoverVertex>.stride) {
            scene.verts.withUnsafeBytes { slot.0.contents().advanced(by: slot.1).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            meshBuffer = slot
        }

        for batch in scene.batches {
            switch batch.kind {
            case .prims:
                guard let (buffer, offset) = primBuffer, let state = pipelines[CoverRenderer.key("prim", batch.blend)] else { continue }
                encoder.setRenderPipelineState(state)
                bind(&uniforms)
                encoder.setVertexBuffer(buffer, offset: offset + batch.start * MemoryLayout<CoverPrim>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: batch.count)
            case .mesh:
                guard let (buffer, offset) = meshBuffer, let state = pipelines[CoverRenderer.key("mesh", batch.blend)] else { continue }
                encoder.setRenderPipelineState(state)
                bind(&uniforms)
                encoder.setVertexBuffer(buffer, offset: offset + batch.start * MemoryLayout<CoverVertex>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.count)
            case .stars:
                guard let s = stars(field), let state = pipelines[CoverRenderer.key("star", batch.blend)] else { continue }
                encoder.setRenderPipelineState(state)
                encoder.setVertexBuffer(s.buffer, offset: 0, index: 0)
                // under the lens every nearby star is drawn three times: itself, fading, and its two images
                for pass in 0..<(uniforms.lensStrength > 0 ? 3 : 1) {
                    var u = uniforms
                    u.starPass = Float(pass)
                    bind(&u)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: s.count)
                }
            case .moon(let stage):
                guard let state = pipelines[CoverRenderer.key("moon", batch.blend)] else { continue }
                encoder.setRenderPipelineState(state)
                bind(&uniforms)
                var m = scene.moon
                m.stage = Float(stage)
                encoder.setVertexBytes(&m, length: MemoryLayout<MoonUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&m, length: MemoryLayout<MoonUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
    }
}

/// The view a cover's moving sky is shown in. It sits over the painted sky and lets clicks through.
final class CoverSkyView: NSView {
    var design: CoverDesign?
    var progress = 0.0
    var bookmarks = 0
    var moving = false          // the sky animates
    var awake = true            // someone can see it
    var hoverBox: HoverBox?
    private var stale = true
    private var drawnSize = CGSize.zero
    private weak var watched: NSClipView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.isOpaque = false
        return layer
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let old = watched {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
            watched = nil
        }
        guard window != nil else {
            CoverRenderer.shared?.remove(self)
            return
        }
        // scrolling brings other covers into view, which have to be drawn even if nothing is animating
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
            watched = clip
        }
        stale = true
        CoverRenderer.shared?.add(self)
    }

    @objc private func scrolled() { CoverRenderer.shared?.wake() }

    override func layout() {
        super.layout()
        if bounds.size != drawnSize { refresh() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    /// Redraw at the next refresh even if nothing is animating.
    func refresh() {
        stale = true
        CoverRenderer.shared?.wake()
    }

    var isShowing: Bool {
        window != nil && design != nil && bounds.width > 2 && bounds.height > 2 && !visibleRect.isEmpty
    }

    func wantsFrame(_ now: Double) -> Bool {
        if stale { return true }
        guard awake else { return false }
        return moving || hoverBox?.info(now) != nil
    }

    func drew() {
        stale = false
        drawnSize = bounds.size
    }

    /// Shows one part of the shared sheet (or nothing).
    func show(_ surface: IOSurfaceRef?, _ rect: CGRect) {
        guard let layer else { return }
        if surface == nil {
            if layer.contents != nil { layer.contents = nil }
            return
        }
        layer.contents = surface
        layer.contentsRect = rect
    }
}

struct CoverSky: NSViewRepresentable {
    let design: CoverDesign
    let progress: Double
    let bookmarks: Int
    let moving: Bool
    let awake: Bool
    let hovering: Bool          // read so that the view is updated, and woken, when the pointer arrives
    let hoverBox: HoverBox

    func makeNSView(context: Context) -> CoverSkyView { CoverSkyView(frame: .zero) }

    func updateNSView(_ view: CoverSkyView, context: Context) {
        view.design = design
        view.progress = progress
        view.bookmarks = bookmarks
        view.moving = moving
        view.awake = awake
        view.hoverBox = hoverBox
        view.refresh()
    }
}
