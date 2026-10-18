import AppKit
import CoreVideo
import IOSurface
import Metal
import QuartzCore
import SwiftUI

// Draws the moving sky of every visible cover on the GPU. One display link drives them all; each
// frame the CPU lays out a short list of shapes per cover (CoverScene) and the shaders do the rest.
//
// The covers due at a refresh are drawn side by side on one sheet, in a single render pass, and then
// copied out into small surfaces of their own (three per cover, taking turns), which are handed to the
// covers' layers together in one transaction. One pass instead of one per cover is most of the saving:
// setting up a pass costs the CPU far more than the few shapes a cover draws in it.
//
// Most of what a sky does is slow — mist breathing, stars swaying by their parallax, the Moon nodding —
// and moves well under a pixel between frames, so a cover is redrawn 15 times a second. One with
// something fast on it (a meteor in flight, a pulsar's turning beams) is drawn 30 times, and the one under
// the pointer at every refresh. When nothing moves, or nobody can see the covers, nothing is drawn.

final class CoverRenderer {
    static let shared = CoverRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private var pipelines: [MTLRenderPipelineState] = []
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

    /// Shape data for the frame being drawn; three take turns, like the covers' surfaces.
    private let arenas = [Arena(), Arena(), Arena()]
    private var frame = 0
    private var busy = false
    private var shown = Set<ObjectIdentifier>()
    private static let chunkSize = 1 << 20

    /// The sheet the covers are drawn on together, before each is copied out to its own surface.
    private var sheetTexture: MTLTexture?
    private static let rowWidth = 4096          // pixels; a wider cover gets a row to itself
    private static let sheetLimit = 8192

    private static let calm = CAFrameRateRange(minimum: 15, maximum: 15, preferred: 15)
    private static let brisk = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
    private static let lively = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    private enum Shader: Int, CaseIterable {
        case prim, mesh, star, moon
        var name: String { ["prim", "mesh", "star", "moon"][rawValue] }
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: CoverShaders.source, options: nil) else { return nil }
        self.device = device
        self.queue = queue
        for shader in Shader.allCases {
            for blend in [CoverBlend.normal, .screen] {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = library.makeFunction(name: shader.name + "_vertex")
                desc.fragmentFunction = library.makeFunction(name: shader.name + "_fragment")
                let color = desc.colorAttachments[0]!
                color.pixelFormat = .bgra8Unorm
                color.isBlendingEnabled = true
                // colours arrive premultiplied; "screen" is 1 − (1 − src)(1 − dst) on every channel
                color.sourceRGBBlendFactor = blend == .screen ? .oneMinusDestinationColor : .one
                color.sourceAlphaBlendFactor = blend == .screen ? .oneMinusDestinationAlpha : .one
                color.destinationRGBBlendFactor = blend == .screen ? .one : .oneMinusSourceAlpha
                color.destinationAlphaBlendFactor = blend == .screen ? .one : .oneMinusSourceAlpha
                guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
                pipelines.append(state)         // in the order pipeline(_:_:) reads them
            }
        }
    }

    private func pipeline(_ shader: Shader, _ blend: CoverBlend) -> MTLRenderPipelineState {
        pipelines[shader.rawValue * 2 + (blend == .screen ? 1 : 0)]
    }

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
        let perfStart = CoverPerf.now()
        defer { CoverPerf.tick += CoverPerf.now() - perfStart; CoverPerf.ticks += 1; CoverPerf.report() }
        guard !busy else { return }
        let now = Date().timeIntervalSince(CoverClock.start)
        let visible = views.allObjects.filter { $0.isShowing }
        let ids = Set(visible.map { ObjectIdentifier($0) })
        // the liveliest cover in view sets the pace of the refreshes
        let pace = visible.reduce(0.0) { max($0, $1.pace(now)) }
        // A cover is drawn when its next frame is due, or it has just come into view;
        // the others keep showing what they last drew.
        let due = visible.filter { $0.wantsFrame(now) || !shown.contains(ObjectIdentifier($0)) }
        if due.isEmpty && ids == shown {
            if pace == 0 { rest(link) }
            return
        }
        let rate = pace >= 60 ? CoverRenderer.lively : (pace >= 30 ? CoverRenderer.brisk : CoverRenderer.calm)
        if link.preferredFrameRateRange != rate { link.preferredFrameRateRange = rate }
        draw(due, ids: ids, now: now)
    }

    /// Nothing is moving, or nobody can see it: stop until wake(), and give back what isn't needed meanwhile.
    private func rest(_ link: CADisplayLink) {
        link.isPaused = true
        sheetTexture = nil
        for view in views.allObjects { view.releaseSpares() }
    }

    // MARK: Drawing

    /// A surface for a cover's picture, shared with Core Animation without copying.
    static func makeTarget(_ device: MTLDevice, width: Int, height: Int) -> CoverSkyView.Target? {
        let properties: [CFString: Any] = [kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                                           kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else { return nil }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB), let plist = srgb.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist)
        }
        return CoverSkyView.Target(surface: surface, texture: texture)
    }

    /// The shared sheet, at least this big. It only ever grows, until the covers rest.
    private func sheetAtLeast(width: Int, height: Int) -> MTLTexture? {
        if let s = sheetTexture, s.width >= width, s.height >= height { return s }
        let w = min(CoverRenderer.sheetLimit, max(sheetTexture?.width ?? 0, (width + 255) & ~255))
        let h = min(CoverRenderer.sheetLimit, max(sheetTexture?.height ?? 0, (height + 255) & ~255))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        sheetTexture = device.makeTexture(descriptor: desc)
        return sheetTexture
    }

    /// Where one cover goes on the sheet.
    private struct Cell {
        let view: CoverSkyView
        let design: CoverDesign
        let size: CGSize
        let scale: Double
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let target: CoverSkyView.Target
    }

    private func draw(_ due: [CoverSkyView], ids: Set<ObjectIdentifier>, now: Double) {
        let perfDraw = CoverPerf.now()
        defer { CoverPerf.drawTotal += CoverPerf.now() - perfDraw }
        // covers that have scrolled out of sight let go of their spare surfaces; each keeps the picture it
        // shows, so it reappears at once when scrolled back (a hidden window's covers keep everything)
        for view in views.allObjects where !ids.contains(ObjectIdentifier(view)) && view.windowShowing { view.dropSurfaces() }
        shown = ids
        guard !due.isEmpty else { return }

        // Lay the covers out on the sheet in rows, a pixel apart
        var cells: [Cell] = []
        cells.reserveCapacity(due.count)
        var x = 0, y = 0, row = 0, extent = 0
        for view in due {
            guard let design = view.design else { continue }
            let size = view.bounds.size
            let scale = Double(view.window?.backingScaleFactor ?? 2)
            let width = Int((Double(size.width) * scale).rounded()), height = Int((Double(size.height) * scale).rounded())
            guard width >= 1, height >= 1, width <= CoverRenderer.sheetLimit, height <= CoverRenderer.sheetLimit else {
                view.drew(now, fast: false)         // nothing sensible to draw; don't ask again until it changes
                continue
            }
            if x > 0 && x + width > CoverRenderer.rowWidth {
                x = 0
                y += row + 1
                row = 0
            }
            guard y + height <= CoverRenderer.sheetLimit else { break }     // the rest are drawn at the next refresh
            guard let target = view.nextTarget(device, width: width, height: height) else { continue }
            cells.append(Cell(view: view, design: design, size: size, scale: scale, x: x, y: y, width: width, height: height,
                              target: target))
            x += width + 1
            row = max(row, height)
            extent = max(extent, x)
        }
        let sheetHeight = y + row
        guard !cells.isEmpty, let sheet = sheetAtLeast(width: extent, height: sheetHeight),
              let commands = queue.makeCommandBuffer() else { return }
        frame = (frame + 1) % arenas.count
        let arena = arenas[frame]
        arena.chunk = 0
        arena.used = 0

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sheet
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.renderTargetWidth = min(extent, sheet.width)
        pass.renderTargetHeight = min(sheetHeight, sheet.height)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let sky = SkyNow.current
        let kp = SpaceWeather.shared.kp
        var bound = Bound()
        for cell in cells {
            let view = cell.view
            encoder.setViewport(MTLViewport(originX: Double(cell.x), originY: Double(cell.y), width: Double(cell.width),
                                            height: Double(cell.height), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: cell.x, y: cell.y, width: cell.width, height: cell.height))
            let perfCompose = CoverPerf.now()
            cell.design.compose(into: scene, size: cell.size, scale: cell.scale, t: view.moving ? now : 0, sky: sky, kp: kp,
                                progress: view.progress, bookmarks: view.bookmarks, hover: view.hoverBox?.info(now))
            let perfEncode = CoverPerf.now()
            encode(scene, field: cell.design.field, arena: arena, encoder: encoder, bound: &bound)
            CoverPerf.compose += perfEncode - perfCompose
            CoverPerf.encode += CoverPerf.now() - perfEncode
            CoverPerf.covers += 1
            CoverPerf.prims += scene.prims.count
            CoverPerf.verts += scene.verts.count
            CoverPerf.batches += scene.batches.count
            view.drew(now, fast: scene.fast)
        }
        encoder.endEncoding()

        // each cover's picture, copied from the sheet into the surface it will be shown from
        guard let blit = commands.makeBlitCommandEncoder() else { return }
        for cell in cells {
            blit.copy(from: sheet, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: cell.x, y: cell.y, z: 0),
                      sourceSize: MTLSize(width: cell.width, height: cell.height, depth: 1),
                      to: cell.target.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()

        // once the GPU has finished, give every cover its new picture in one go
        busy = true
        let finished = cells.map { (view: $0.view, surface: $0.target.surface) }
        commands.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let perfShow = CoverPerf.now()
                self.busy = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for d in finished where self.shown.contains(ObjectIdentifier(d.view)) { d.view.show(d.surface) }
                CATransaction.commit()
                CoverPerf.show += CoverPerf.now() - perfShow
            }
        }
        let perfCommit = CoverPerf.now()
        commands.commit()
        CoverPerf.commit += CoverPerf.now() - perfCommit
        CoverPerf.frames += 1
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

    /// What the encoder already has, so that it isn't set again.
    private struct Bound {
        var pipeline: MTLRenderPipelineState?
        var shapes: MTLBuffer?
    }

    /// Turns a composed scene into draw calls, in the order it was laid out.
    private func encode(_ scene: CoverScene, field: SkyField, arena: Arena, encoder: MTLRenderCommandEncoder, bound: inout Bound) {
        func use(_ state: MTLRenderPipelineState) {
            if bound.pipeline !== state {
                encoder.setRenderPipelineState(state)
                bound.pipeline = state
            }
        }
        func shapes(_ buffer: MTLBuffer, _ offset: Int) {
            if bound.shapes === buffer {
                encoder.setVertexBufferOffset(offset, index: 0)
            } else {
                encoder.setVertexBuffer(buffer, offset: offset, index: 0)
                bound.shapes = buffer
            }
        }
        func copy<T>(_ items: [T]) -> (MTLBuffer, Int)? {
            guard !items.isEmpty, let slot = allocate(arena, items.count * MemoryLayout<T>.stride) else { return nil }
            items.withUnsafeBytes { slot.0.contents().advanced(by: slot.1).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            return slot
        }

        // the cover's uniforms, bound once for all of its shapes
        let uniformSize = MemoryLayout<CoverUniforms>.stride
        guard let (uniformBuffer, uniformOffset) = allocate(arena, uniformSize) else { return }
        uniformBuffer.contents().advanced(by: uniformOffset).storeBytes(of: scene.uniforms, as: CoverUniforms.self)
        encoder.setVertexBuffer(uniformBuffer, offset: uniformOffset, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: uniformOffset, index: 1)

        let primBuffer = copy(scene.prims)
        let meshBuffer = copy(scene.verts)
        for batch in scene.batches {
            switch batch.kind {
            case .prims:
                guard let (buffer, offset) = primBuffer else { continue }
                use(pipeline(.prim, batch.blend))
                shapes(buffer, offset + batch.start * MemoryLayout<CoverPrim>.stride)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: batch.count)
            case .mesh:
                guard let (buffer, offset) = meshBuffer else { continue }
                use(pipeline(.mesh, batch.blend))
                shapes(buffer, offset + batch.start * MemoryLayout<CoverVertex>.stride)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.count)
            case .stars:
                guard let s = stars(field) else { continue }
                use(pipeline(.star, batch.blend))
                shapes(s.buffer, 0)
                if scene.uniforms.lensStrength > 0 {
                    // under the lens every nearby star is drawn three times: itself, fading, and its two images
                    for pass in 0..<3 {
                        var u = scene.uniforms
                        u.starPass = Float(pass)
                        encoder.setVertexBytes(&u, length: uniformSize, index: 1)
                        encoder.setFragmentBytes(&u, length: uniformSize, index: 1)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: s.count)
                    }
                    encoder.setVertexBuffer(uniformBuffer, offset: uniformOffset, index: 1)
                    encoder.setFragmentBuffer(uniformBuffer, offset: uniformOffset, index: 1)
                } else {
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: s.count)
                }
            case .moon(let stage):
                use(pipeline(.moon, batch.blend))
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
    private var fast = false    // the last frame had something quick in it
    private var drawnSize = CGSize.zero
    private weak var watched: NSClipView?
    private weak var watchedWindow: NSWindow?

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
        if let old = watchedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: old)
            watchedWindow = nil
        }
        guard let window else {
            CoverRenderer.shared?.remove(self)
            return
        }
        // a window that is covered, minimised or hidden stops its covers; showing it again starts them
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSWindow.didChangeOcclusionStateNotification,
                                               object: window)
        watchedWindow = window
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

    /// The window is on screen and not completely covered.
    var windowShowing: Bool {
        guard let window else { return false }
        if CoverPerf.force { return window.isVisible && !window.isMiniaturized }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    var isShowing: Bool {
        windowShowing && design != nil && bounds.width > 2 && bounds.height > 2 && !visibleRect.isEmpty
    }

    private var lastDrawn = -1.0

    /// How many times a second this cover wants drawing: 0 when it is still or nobody can see it.
    func pace(_ now: Double) -> Double {
        guard awake || CoverPerf.force else { return 0 }
        // The lens follows the pointer at every refresh while the pointer moves or the lens fades in or
        // out. A pointer resting on a cover leaves it at its usual pace.
        if let box = hoverBox, let info = box.info(now), info.strength < 1 || now - box.movedAt < 0.3 { return 60 }
        guard moving else { return 0 }
        return fast ? 30 : 15
    }

    /// Whether this cover needs drawing at this refresh.
    func wantsFrame(_ now: Double) -> Bool {
        if stale { return true }
        let p = pace(now)
        if p >= 60 { return true }
        return p > 0 && now - lastDrawn >= 1 / p - 0.004
    }

    func drew(_ now: Double, fast: Bool) {
        stale = false
        self.fast = fast
        lastDrawn = now
        drawnSize = bounds.size
    }

    // MARK: Surfaces

    /// One picture of this cover's moving sky, drawn by the GPU and shown by Core Animation.
    struct Target {
        let surface: IOSurfaceRef
        let texture: MTLTexture
    }

    private var targets: [Target] = []
    private var targetSize = (width: 0, height: 0)
    private var nextIndex = 0

    /// The surface to draw the next frame into. Three take turns: one on screen, one being drawn, one spare.
    func nextTarget(_ device: MTLDevice, width: Int, height: Int) -> Target? {
        if targets.isEmpty || targetSize.width != width || targetSize.height != height {
            var made: [Target] = []
            for _ in 0..<3 {
                guard let t = CoverRenderer.makeTarget(device, width: width, height: height) else { return nil }
                made.append(t)
            }
            targets = made
            targetSize = (width, height)
            nextIndex = 0
        }
        let t = targets[nextIndex]
        nextIndex = (nextIndex + 1) % targets.count
        return t
    }

    /// Scrolled out of sight: let go of the surfaces until the cover comes back. (The layer keeps the
    /// one it is showing, so the cover is not blank while its next picture is drawn.)
    func dropSurfaces() {
        guard !targets.isEmpty else { return }
        releaseSpares()
        stale = true
    }

    /// Resting: the layer keeps the picture it shows; fresh surfaces are made when drawing starts again.
    func releaseSpares() {
        targets = []
        targetSize = (0, 0)
    }

    /// Shows a finished picture (or nothing).
    func show(_ surface: IOSurfaceRef?) {
        guard let layer else { return }
        guard let surface else {
            if layer.contents != nil { layer.contents = nil }
            return
        }
        layer.contents = surface
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

// A developer's meter for the covers, off unless ~/Developer/Folio/build/coverperf.on exists when Folio starts.
// Then every five seconds a line goes to ~/Developer/Folio/build/coverperf.log saying where the time went, and
// every ten seconds a sample of the main thread's stack shows what it was busy with. With coverperf.force there
// too, covers draw even when Folio is in the background (so they can be measured without bringing it forward).
enum CoverPerf {
    static var sections = [UInt64](repeating: 0, count: 16)
    static let names = ["setup", "sky", "orbs", "aurora", "deepsky", "lens", "trails", "figure", "planets", "flare",
                        "comet", "moon", "meteors", "orrery", "ring", "x"]
    static var compose: UInt64 = 0, encode: UInt64 = 0, tick: UInt64 = 0, show: UInt64 = 0, drawTotal: UInt64 = 0, commit: UInt64 = 0
    static var ticks = 0, covers = 0, prims = 0, verts = 0, batches = 0, frames = 0
    static var windowStart: UInt64 = 0, cpuStart: UInt64 = 0, mainStart: UInt64 = 0
    @inline(__always) static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    static let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Developer/Folio/build")
    static let url = folder.appendingPathComponent("coverperf.log")
    static let enabled = FileManager.default.fileExists(atPath: folder.appendingPathComponent("coverperf.on").path)
    static let force = enabled && FileManager.default.fileExists(atPath: folder.appendingPathComponent("coverperf.force").path)
    static func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func report() {
        guard enabled else { return }
        let n = now()
        if windowStart == 0 {
            windowStart = n
            cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
            mainStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            #if arch(arm64)
            MainThreadSampler.shared.start()
            #endif
            return
        }
        let span = Double(n - windowStart)
        guard span >= 5e9 else { return }
        let cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID), main = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        func pct(_ v: UInt64) -> String { String(format: "%.1f", Double(v) / span * 100) }
        let c = max(1, covers)
        var line = "\(Date()) \(Bundle.main.bundlePath) force=\(force) span=\(String(format: "%.1f", span / 1e9))s"
        line += " cpu=\(pct(cpu &- cpuStart)) main=\(pct(main &- mainStart))"
        line += " tick=\(pct(tick)) draw=\(pct(drawTotal)) compose=\(pct(compose)) encode=\(pct(encode)) commit=\(pct(commit)) show=\(pct(show))"
        line += " ticks=\(ticks) frames=\(frames) covers=\(covers) perFrame=\(String(format: "%.1f", Double(covers) / Double(max(1, frames))))"
        line += " prims=\(prims / c) verts=\(verts / c) batches=\(batches / c) |"
        for (i, name) in names.enumerated() where sections[i] > 0 {
            line += " \(name)=\(String(format: "%.2f", Double(sections[i]) / span * 100))"
        }
        line += "\n"
        append(line)
        windowStart = n
        cpuStart = cpu
        mainStart = main
        sections = [UInt64](repeating: 0, count: 16)
        compose = 0; encode = 0; tick = 0; show = 0; drawTotal = 0; commit = 0
        ticks = 0; covers = 0; prims = 0; verts = 0; batches = 0; frames = 0
    }
}

#if arch(arm64)
/// Part of the developer's meter: samples the main thread's call stack 500 times a second (stopping it for a
/// few microseconds each time) and every ten seconds writes down which functions the busy samples were in.
final class MainThreadSampler {
    static let shared = MainThreadSampler()
    private var target: thread_act_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private let lock = NSLock()
    private var stacks: [[UInt]] = []
    private var dropped = 0
    private var started = false
    private var windowStart = Date()

    /// Call on the main thread.
    func start() {
        guard !started else { return }
        started = true
        target = mach_thread_self()
        let me = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackLow = stackHigh &- UInt(pthread_get_stacksize_np(me))
        windowStart = Date()
        let worker = Thread { self.run() }
        worker.name = "Folio main-thread sampler"
        worker.qualityOfService = .userInteractive
        worker.start()
    }

    private func run() {
        let thread = target, low = stackLow, high = stackHigh
        let depth = 160
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: depth)
        let words = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF            // drops pointer-authentication bits
        var state = arm_thread_state64_t()
        var lastReport = Date()
        while true {
            usleep(2000)
            // Nothing between suspending and resuming may allocate or take a lock: the main thread might hold it.
            guard thread_suspend(thread) == KERN_SUCCESS else { continue }
            var count = words
            let got = withUnsafeMutablePointer(to: &state) { p in
                p.withMemoryRebound(to: natural_t.self, capacity: Int(words)) {
                    thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count) == KERN_SUCCESS
                }
            }
            var n = 0
            if got {
                // x0–x28, then fp, lr, sp and pc: the same layout whatever the SDK names the fields
                let (fp0, lr, pc) = withUnsafeBytes(of: &state) { raw in
                    (raw.load(fromByteOffset: 232, as: UInt.self), raw.load(fromByteOffset: 240, as: UInt.self),
                     raw.load(fromByteOffset: 256, as: UInt.self))
                }
                frames[0] = pc & mask
                frames[1] = lr & mask
                n = 2
                var fp = fp0
                while n < depth, fp >= low, fp &+ 16 <= high, fp & 7 == 0 {
                    let record = UnsafePointer<UInt>(bitPattern: fp)!
                    let next = record[0], ret = record[1] & mask
                    if ret == 0 { break }
                    frames[n] = ret
                    n += 1
                    if next <= fp { break }
                    fp = next
                }
            }
            thread_resume(thread)
            if n > 0 {
                let stack = Array(UnsafeBufferPointer(start: frames, count: n))
                lock.lock()
                if stacks.count < 30_000 { stacks.append(stack) } else { dropped += 1 }
                lock.unlock()
            }
            if Date().timeIntervalSince(lastReport) >= 10 {
                lastReport = Date()
                DispatchQueue.main.async { self.report() }
            }
        }
    }

    private func report() {
        lock.lock()
        let taken = stacks
        let lost = dropped
        stacks.removeAll(keepingCapacity: true)
        dropped = 0
        lock.unlock()
        let span = Date().timeIntervalSince(windowStart)
        windowStart = Date()
        guard !taken.isEmpty else { return }

        var names: [UInt: String] = [:]
        func name(_ pc: UInt) -> String {
            if let known = names[pc] { return known }
            var info = Dl_info()
            var result = String(format: "0x%lx", pc)
            // a return address minus one is inside the call, so it is credited to the caller
            if pc > 1, dladdr(UnsafeRawPointer(bitPattern: pc - 1), &info) != 0 {
                let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                let symbol = info.dli_sname.map { demangle(String(cString: $0)) } ?? "?"
                result = symbol + "  [" + image + "]"
            }
            names[pc] = result
            return result
        }

        /// The busy samples as a tree from the run loop down, to see what set each piece of work going.
        final class Node {
            var count = 0
            var children: [String: Node] = [:]
        }
        let root = Node()
        var idle = 0, bursts = 0, wasBusy = false
        var selfCounts: [String: Int] = [:], totals: [String: Int] = [:]
        for stack in taken {
            let leaf = name(stack[0])
            if leaf.hasPrefix("mach_msg") {                             // waiting in the run loop
                idle += 1
                wasBusy = false
                continue
            }
            if !wasBusy { bursts += 1 }
            wasBusy = true
            selfCounts[leaf, default: 0] += 1
            var seen = Set<String>()
            var node = root
            node.count += 1
            for pc in stack.reversed() {
                let n = name(pc)
                if seen.insert(n).inserted { totals[n, default: 0] += 1 }
                let child = node.children[n] ?? Node()
                node.children[n] = child
                child.count += 1
                node = child
            }
        }
        let busy = taken.count - idle
        var out = String(format: "== main thread: %.1f s, %d samples (%d lost), busy in %.1f%% of them, in %d bursts (%.1f a second, %.1f samples each) ==\n",
                         span, taken.count, lost, Double(busy) / Double(max(1, taken.count)) * 100, bursts,
                         Double(bursts) / max(0.1, span), Double(busy) / Double(max(1, bursts)))
        if busy > 0 {
            func list(_ title: String, _ counts: [String: Int], _ top: Int) {
                out += "  \(title) (share of busy samples):\n"
                for (key, value) in counts.sorted(by: { $0.value > $1.value }).prefix(top) {
                    out += String(format: "   %5.1f%%  ", Double(value) / Double(busy) * 100) + String(key.prefix(160)) + "\n"
                }
            }
            list("self", selfCounts, 25)
            list("total", totals, 50)
            // the tree, down to branches of at least 3%; a branch that is all of its parent is not indented
            out += "  tree (share of busy samples):\n"
            let floor = max(1, busy * 3 / 100)
            func walk(_ node: Node, _ depth: Int) {
                let kids = node.children.filter { $0.value.count >= floor }.sorted { $0.value.count > $1.value.count }
                for (key, child) in kids {
                    let sole = kids.count == 1 && child.count == node.count
                    let indent = sole ? depth : depth + 1
                    out += String(repeating: " ", count: min(60, indent)) +
                        String(format: "%5.1f%%  ", Double(child.count) / Double(busy) * 100) + String(key.prefix(150)) + "\n"
                    walk(child, indent)
                }
            }
            walk(root, 2)
        }
        CoverPerf.append(out)
    }

    private func demangle(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return symbol }
        return symbol.withCString { p in
            guard let fn = swiftDemangle, let out = fn(p, strlen(p), nil, nil, 0) else { return symbol }
            defer { free(out) }
            return String(cString: out)
        }
    }
}

/// The Swift runtime's demangler, looked up by name.
private typealias SwiftDemangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                  UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
private let swiftDemangle: SwiftDemangle? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }   // RTLD_DEFAULT
    return unsafeBitCast(symbol, to: SwiftDemangle.self)
}()
#endif
