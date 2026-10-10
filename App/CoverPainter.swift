import SwiftUI

// Paints the covers. Everything drawn here is grounded in the real sky:
//
//  static layer  – sky colour, the Milky Way from its real outline, zodiacal light along the real
//                  ecliptic, and each deep-sky object drawn after its real structure;
//  animated      – stars at their catalogue positions, colours and brightnesses, shifting by their
//                  real distances (parallax); variable stars following their real light curves;
//                  tonight's planets and Moon; meteors from the showers active tonight, flying out of
//                  their real radiants at their real speeds; aurora as strong as NOAA's live Kp index;
//                  replays of famous eclipses, comets and supernovae; your reading progress as a real
//                  Keplerian orbit; and a point-mass gravitational lens under the pointer.

// MARK: - Small helpers

enum CV {
    static let tau = 2 * Double.pi

    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }

    static func smooth(_ x: Double) -> Double {
        let t = clamp(x)
        return t * t * (3 - 2 * t)
    }

    static func mix(_ a: RGB01, _ b: RGB01, _ t: Double) -> RGB01 {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    /// Stateless hash to 0..<1, for deterministic per-event randomness.
    static func hash(_ a: UInt64, _ b: UInt64) -> Double {
        var z = a ^ (b &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (Double(a.x) + Double(b.x)) / 2, y: (Double(a.y) + Double(b.y)) / 2)
    }

    static func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x) - Double(b.x)
        let dy = Double(a.y) - Double(b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func circle(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: Double(c.x) - r, y: Double(c.y) - r, width: 2 * r, height: 2 * r))
    }

    /// A smooth curve through the points (quadratic segments between midpoints).
    static func curve(_ pts: [CGPoint], closed: Bool = false) -> Path {
        var p = Path()
        guard pts.count > 1 else { return p }
        if pts.count == 2 {
            p.move(to: pts[0])
            p.addLine(to: pts[1])
            return p
        }
        if closed {
            let n = pts.count
            p.move(to: mid(pts[n - 1], pts[0]))
            for i in 0..<n { p.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i]) }
            p.closeSubpath()
        } else {
            p.move(to: pts[0])
            for i in 1..<(pts.count - 1) { p.addQuadCurve(to: mid(pts[i], pts[i + 1]), control: pts[i]) }
            p.addLine(to: pts[pts.count - 1])
        }
        return p
    }

    static func lightYears(_ ly: Double) -> String {
        guard ly > 0, ly.isFinite else { return "" }
        if ly < 20 { return String(format: "%.1f light-years", ly) }
        if ly < 1000 { return "\(Int(ly.rounded())) light-years" }
        let rounded = Int((ly / 100).rounded() * 100)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return "about " + (f.string(from: NSNumber(value: rounded)) ?? "\(rounded)") + " light-years"
    }

    /// "Its light left around 1528" — the year the starlight you see set out.
    static func departure(_ ly: Double) -> String? {
        guard ly >= 4, ly < 5000, ly.isFinite else { return nil }
        let year = Calendar.current.component(.year, from: Date()) - Int(ly.rounded())
        if year > 0 { return "its light left around \(year)" }
        return "its light left around \(-year + 1) BC"
    }

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEjmm")
        return f
    }()

    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()
}

/// Colours of real emission and scattering processes.
enum SkyInk {
    static let hAlpha: RGB01 = (1.0, 0.34, 0.44)        // hydrogen-alpha, 656 nm
    static let magenta: RGB01 = (0.96, 0.42, 0.66)      // hydrogen-alpha + hydrogen-beta
    static let oxygen: RGB01 = (0.36, 0.92, 0.86)       // doubly ionised oxygen, 501 nm
    static let dust: RGB01 = (0.46, 0.62, 1.0)          // starlight scattered by dust (why reflection nebulae are blue)
    static let warm: RGB01 = (1.0, 0.86, 0.62)          // old yellow stars in galaxy bulges
    static let hotStar: RGB01 = (0.76, 0.86, 1.0)
    static let white: RGB01 = (1.0, 1.0, 1.0)
    static let prominence: RGB01 = (1.0, 0.32, 0.46)    // hydrogen-alpha at the Sun's limb
    static let auroraGreen: RGB01 = (0.36, 1.0, 0.56)   // atomic oxygen, 557.7 nm
    static let auroraRed: RGB01 = (1.0, 0.24, 0.32)     // atomic oxygen, 630.0 nm
    static let auroraViolet: RGB01 = (0.58, 0.36, 1.0)  // ionised nitrogen, 427.8 nm
}

extension SkyShowerInfo {
    static let all: [SkyShowerInfo] = (0..<Int(sky_shower_count())).map { SkyShowerInfo($0) }
}

/// Where each meteor shower's radiant falls on a constellation's cover (nil = below the horizon).
final class ShowerRadiants {
    static let shared = ShowerRadiants()
    private var cache: [Int: [CGPoint?]] = [:]

    func points(_ f: SkyField) -> [CGPoint?] {
        if let p = cache[f.index] { return p }
        let pts = SkyShowerInfo.all.map { f.project(ra: $0.ra, dec: $0.dec) }
        cache[f.index] = pts
        return pts
    }
}

/// The gravitational lens under the pointer.
struct Lens {
    let center: CGPoint      // cover units
    let theta: Double        // Einstein radius, cover units
    let strength: Double     // 0…1, eases in and out with the pointer
}

/// What is happening on a cover at a given moment: eclipse, comet and supernova replays.
struct CoverEvents {
    struct Eclipse {
        let kind: Int        // 0 total solar, 1 annular, 2 total lunar, 3 partial lunar, 4 partial solar, 5 penumbral
        let corona: Int      // 0 solar minimum, 1 middle of the cycle, 2 maximum
        let u: Double        // 0…1 through the event
        let title: String
        let detail: String
        let seed: UInt64
    }
    struct Comet {
        let index: Int
        let u: Double
        let seed: UInt64
    }
    struct Flare {
        let u: Double
    }

    var eclipse: Eclipse?
    var comet: Comet?
    var flare: Flare?
    var dimming = 0.0        // Betelgeuse's Great Dimming, 0…1
}

struct SolarGeometry {
    let x: Double            // Moon centre relative to the Sun, in solar radii
    let y: Double
    let moonR: Double        // apparent size of the Moon, in solar radii
    let sep: Double
    let totality: Double     // 0…1
    let coverage: Double     // 0…1, roughly how much of the Sun is hidden
    let fade: Double
}

struct LunarGeometry {
    let x: Double            // centre of Earth's shadow relative to the Moon, in lunar radii
    let y: Double
    let umbra: Double        // 0…1, how deep the Moon is in the umbra
    let fade: Double
}

// MARK: - Entry points

extension CoverDesign {
    /// The event schedule. Every cover replays real events on its own slow cycle.
    func events(t: Double, sky: SkyNow) -> CoverEvents {
        var e = CoverEvents()
        guard t > 0 else { return e }

        if hasMoon {
            if let today = sky.eclipseToday {
                // A real eclipse is happening today: show it every two and a half minutes.
                let cycle = 150.0, length = 66.0
                let local = (t + eclipsePhase).truncatingRemainder(dividingBy: cycle)
                if local < length {
                    let map = [0, 1, 0, 4, 2, 3, 5]
                    let kind = map[max(0, min(6, today.kind))]
                    e.eclipse = .init(kind: kind, corona: 2, u: local / length, title: "\(today.title) · today",
                                      detail: "A real eclipse is happening on Earth today", seed: 7)
                }
            } else if sky_replay_count() > 0 {
                let length = 66.0
                let x = t + eclipsePhase
                let local = x.truncatingRemainder(dividingBy: eclipseCycle)
                if local < length {
                    let n = Int(x / eclipseCycle)
                    let i = (eclipseStart + n) % Int(sky_replay_count())
                    if let r = sky_replay_at(Int32(i)) {
                        e.eclipse = .init(kind: Int(r.pointee.kind), corona: Int(r.pointee.corona), u: local / length,
                                          title: String(cString: r.pointee.title), detail: String(cString: r.pointee.detail),
                                          seed: UInt64(i + 1))
                    }
                }
            }
        }

        if sky_comet_count() > 0 {
            let length = 84.0
            let x = t + cometPhase
            let local = x.truncatingRemainder(dividingBy: cometCycle)
            if local < length {
                let n = Int(x / cometCycle)
                e.comet = .init(index: (cometStart + n) % Int(sky_comet_count()), u: local / length,
                                seed: meteorSeed &+ UInt64(n))
            }
        }

        if flarePoint != nil {
            let length = 50.0
            let local = (t + flarePhase).truncatingRemainder(dividingBy: flareCycle)
            if local < length { e.flare = .init(u: local / length) }
        }

        let dimLength = 48.0
        let dimLocal = (t + dimPhase).truncatingRemainder(dividingBy: dimCycle)
        if dimLocal < dimLength { e.dimming = pow(sin(Double.pi * dimLocal / dimLength), 1.6) }
        return e
    }

    func drawStatic(_ ctx: inout GraphicsContext, size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }
        let p = CoverPainter(self, size)
        p.background(ctx)
        p.milkyWay(ctx)
        p.zodiacal(ctx)
        p.deepSky(ctx)
        p.grain(ctx)
    }

    func drawAnimated(_ ctx: inout GraphicsContext, size: CGSize, t: Double, clock: Double, sky: SkyNow, kp: Double,
                      progress: Double, bookmarks: Int, hover: HoverInfo?) {
        guard size.width > 2, size.height > 2 else { return }
        let p = CoverPainter(self, size)
        let progress = progress.isFinite ? CV.clamp(progress) : 0
        let ev = events(t: t, sky: sky)
        let night = p.nightFactor(ev)
        let solar = ev.eclipse.map { [0, 1, 4].contains($0.kind) } ?? false

        p.eclipseSky(ctx, night: night, solar: solar)
        p.orbs(ctx, t: t)
        p.aurora(ctx, t: t, kp: kp)
        p.deepSkyLive(ctx, t: t)

        var lens: Lens?
        if let h = hover, size.width >= 100 {
            lens = Lens(center: h.point, theta: 0.05, strength: h.strength)
        }
        if let L = lens { p.lensShadow(ctx, L) }

        p.trails(ctx, t: t)
        p.figure(ctx, t: t, bookmarks: bookmarks)
        p.stars(ctx, t: t, ev: ev, night: night, lens: lens)
        p.planets(ctx, t: t, sky: sky, night: night)
        if let f = ev.flare { p.flare(ctx, t: t, f) }
        if let c = ev.comet { p.comet(ctx, c) }
        p.moon(ctx, t: t, sky: sky, ev: ev)
        p.meteors(ctx, t: t, sky: sky)
        p.orrery(ctx, t: t, progress: progress)
        if let L = lens { p.lensRing(ctx, L) }
    }

    /// The hover caption: what is under the pointer, and what the real sky is doing tonight.
    func drawCaption(_ ctx: inout GraphicsContext, size: CGSize, t: Double, sky: SkyNow, kp: Double,
                     progress: Double, hover: HoverInfo?) {
        guard let h = hover, size.width >= 110 else { return }
        let p = CoverPainter(self, size)
        let progress = progress.isFinite ? CV.clamp(progress) : 0
        let ev = events(t: t, sky: sky)
        let lines = p.caption(at: h.point, visits: h.visits, t: t, sky: sky, kp: kp, progress: progress, ev: ev)
        p.paintCaption(ctx, lines, alpha: h.strength)
    }
}

// MARK: - The painter

struct CoverPainter {
    let d: CoverDesign
    let size: CGSize
    let w: Double            // pixels per cover unit (the cover is 1 unit wide, 1.5 tall)
    let dark: Bool
    let pal: CoverPalette

    init(_ d: CoverDesign, _ size: CGSize) {
        self.d = d
        self.size = size
        self.w = Double(size.width)
        self.dark = d.palette.dark
        self.pal = d.palette
    }

    var units: Double { Double(size.height) / w }

    func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: Double(p.x) * w, y: Double(p.y) * w) }
    func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: y * w) }

    var top01: RGB01 { (pal.top.0 / 255, pal.top.1 / 255, pal.top.2 / 255) }

    func skyAt(_ y: Double) -> RGB01 { CV.mix(top01, pal.bottom01, CV.clamp(y / units)) }

    /// Nebula colour: glowing light on night skies, a soft watercolour stain on twilight ones.
    func neb(_ c: RGB01, _ a: Double) -> Color {
        dark ? skyColor(c, a) : skyColor(CV.mix(c, pal.ink01, 0.38), a * 0.66)
    }

    /// Light on night skies, ink on twilight ones.
    func ink(_ c: RGB01, _ a: Double) -> Color {
        dark ? skyColor(c, a) : skyColor(CV.mix(c, pal.ink01, 0.65), a * 0.85)
    }

    func glow(_ k: GraphicsContext, _ p: CGPoint, _ r: Double, _ c: RGB01, _ a: Double, raw: Bool = false) {
        guard r > 0.05, a > 0.002 else { return }
        let g = Gradient(stops: [
            .init(color: raw ? skyColor(c, a) : neb(c, a), location: 0),
            .init(color: raw ? skyColor(c, a * 0.55) : neb(c, a * 0.55), location: 0.32),
            .init(color: raw ? skyColor(c, a * 0.18) : neb(c, a * 0.18), location: 0.66),
            .init(color: raw ? skyColor(c, 0) : neb(c, 0), location: 1),
        ])
        k.fill(CV.circle(p, r), with: .radialGradient(g, center: p, startRadius: 0, endRadius: r))
    }

    func eglow(_ k: GraphicsContext, _ p: CGPoint, _ rx: Double, _ ry: Double, _ angle: Double,
               _ c: RGB01, _ a: Double, raw: Bool = false) {
        guard rx > 0.05, ry > 0.01 else { return }
        var e = k
        e.translateBy(x: p.x, y: p.y)
        e.rotate(by: .radians(angle))
        e.scaleBy(x: 1, y: ry / rx)
        glow(e, .zero, rx, c, a, raw: raw)
    }

    func dot(_ k: GraphicsContext, _ p: CGPoint, _ r: Double, _ c: RGB01, _ a: Double) {
        k.fill(CV.circle(p, r), with: .color(dark ? skyColor(c, a) : skyColor(pal.ink01, a * 0.55)))
    }

    func ring(_ k: GraphicsContext, _ c: CGPoint, _ r0: Double, _ r1: Double, _ shading: GraphicsContext.Shading) {
        var p = CV.circle(c, r1)
        p.addPath(CV.circle(c, r0))
        k.fill(p, with: shading, style: FillStyle(eoFill: true))
    }

    /// A dark lane of dust: erases light from the layer it is drawn in.
    func lane(_ k: GraphicsContext, _ pts: [CGPoint], _ width: Double, _ alpha: Double) {
        var e = k
        e.blendMode = .destinationOut
        e.stroke(CV.curve(pts), with: .color(Color.black.opacity(alpha)),
                 style: StrokeStyle(lineWidth: max(0.3, width), lineCap: .round, lineJoin: .round))
    }

    /// Soft blobs scattered with a roughly Gaussian falloff.
    func cloud(_ k: GraphicsContext, _ R: Double, _ ratio: Double, _ n: Int, _ colors: [RGB01], _ a: Double,
               _ rng: inout SeededRandom, spread: Double = 0.5, size: (Double, Double) = (0.25, 0.6),
               offset: CGPoint = .zero) {
        guard !colors.isEmpty else { return }
        for i in 0..<n {
            let ang = rng.range(0, CV.tau)
            let g = min(2.2, (-2 * log(max(1e-6, rng.unit()))).squareRoot())
            let rad = R * spread * g * 0.7
            let x = Double(offset.x) + cos(ang) * rad
            let y = Double(offset.y) + sin(ang) * rad * ratio
            let r = R * rng.range(size.0, size.1)
            let alpha = a * rng.range(0.55, 1)
            glow(k, CGPoint(x: x, y: y), r, colors[i % colors.count], alpha)
        }
    }

    func spikes(_ k: GraphicsContext, _ q: CGPoint, _ len: Double, _ color: Color, _ width: Double) {
        guard len > 0.5 else { return }
        var p = Path()
        p.move(to: CGPoint(x: Double(q.x) - len, y: Double(q.y)))
        p.addLine(to: CGPoint(x: Double(q.x) + len, y: Double(q.y)))
        p.move(to: CGPoint(x: Double(q.x), y: Double(q.y) - len))
        p.addLine(to: CGPoint(x: Double(q.x), y: Double(q.y) + len))
        k.stroke(p, with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: q, startRadius: 0, endRadius: len),
                 style: StrokeStyle(lineWidth: max(0.3, width), lineCap: .round))
    }

    // MARK: Static layer

    func background(_ ctx: GraphicsContext) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [CoverPalette.rgb(pal.top), CoverPalette.rgb(pal.bottom)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    /// The Milky Way from its real outline (five brightness levels, dark rifts included).
    func milkyWay(_ ctx: GraphicsContext) {
        let f = d.field
        var levels: [Path] = []
        for level in f.milkyWay {
            var path = Path()
            for poly in level {
                for ring in poly where ring.count > 2 {
                    path.move(to: pt(ring[0]))
                    for q in ring.dropFirst() { path.addLine(to: pt(q)) }
                    path.closeSubpath()
                }
            }
            levels.append(path)
        }
        guard !levels.isEmpty else { return }

        // The diffuse glow
        let tint: RGB01 = dark ? (f.warmMilkyWay ? (1.0, 0.9, 0.76) : (0.84, 0.88, 1.0)) : CV.mix(pal.ink01, (1, 1, 1), 0.25)
        let alpha = dark ? 0.065 : 0.03
        var soft = ctx
        soft.addFilter(.blur(radius: max(0.8, w * 0.022)))
        soft.blendMode = dark ? .screen : .normal
        soft.drawLayer { l in
            for path in levels {
                l.fill(path, with: .color(skyColor(tint, alpha)), style: FillStyle(eoFill: true))
            }
        }

        // Star clouds: unresolved stars, densest where the band is brightest
        guard dark else { return }
        var sharp = ctx
        sharp.blendMode = .screen
        var rng = SeededRandom(seed: d.grainSeed ^ 0x3D3D_5EED)
        let perLevel = min(500, Int(Double(size.width * size.height) / 90))
        for li in 1..<max(1, levels.count) {
            var k = sharp
            k.clip(to: levels[li], style: FillStyle(eoFill: true))
            var dots = Path()
            for _ in 0..<perLevel {
                let x = rng.unit() * Double(size.width), y = rng.unit() * Double(size.height)
                let r = rng.range(0.22, 0.5)
                dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            k.fill(dots, with: .color(skyColor(tint, 0.2)))
        }
    }

    /// Zodiacal light: sunlight scattered by interplanetary dust, a faint band along the ecliptic.
    func zodiacal(_ ctx: GraphicsContext) {
        guard dark, !d.field.ecliptic.isEmpty else { return }
        var c = ctx
        c.addFilter(.blur(radius: max(1, w * 0.035)))
        c.blendMode = .screen
        let runs = d.field.ecliptic
        c.drawLayer { l in
            for run in runs where run.count > 1 {
                var path = Path()
                path.addLines(run.map { self.pt($0) })
                l.stroke(path, with: .color(skyColor((1.0, 0.92, 0.8), 0.06)),
                         style: StrokeStyle(lineWidth: self.w * 0.09, lineCap: .round, lineJoin: .round))
            }
        }
    }

    func grain(_ ctx: GraphicsContext) {
        var rng = SeededRandom(seed: d.grainSeed)
        let n = min(5000, Int(Double(size.width * size.height) / 60))
        var light = Path(), shade = Path()
        for i in 0..<n {
            let x = rng.unit() * Double(size.width), y = rng.unit() * Double(size.height)
            let s = rng.range(0.5, 1.1)
            let r = CGRect(x: x, y: y, width: s, height: s)
            if i % 2 == 0 { light.addRect(r) } else { shade.addRect(r) }
        }
        ctx.fill(light, with: .color(Color.white.opacity(dark ? 0.035 : 0.09)))
        ctx.fill(shade, with: .color(Color.black.opacity(dark ? 0.06 : 0.025)))
    }

    // MARK: Deep-sky objects

    /// Display radius in pixels. Small objects are enlarged so their structure can be seen.
    func radius(_ o: SkyDSO) -> Double {
        var s = o.size
        switch o.kind {
        case SKY_EMISSION: s = max(s, o.variant == 1 ? 0.11 : 0.12)
        case SKY_PILLARS, SKY_ROSETTE: s = max(s, 0.13)
        case SKY_TRIFID: s = max(s, 0.10)
        case SKY_REFLECTION: s = max(s, 0.12)
        case SKY_PN_RING, SKY_PN_BIPOLAR: s = max(s, 0.09)
        case SKY_SNR: s = max(s, 0.10)
        case SKY_GALAXY:
            switch o.variant {
            case 7: s = max(s, 0.13)
            case 8: s = max(s, o.name.contains("Leo") ? 0.17 : 0.13)
            default: s = max(s, 0.11)
            }
        case SKY_CLUSTER:
            switch o.variant {
            case 1: s = max(s, 0.075)
            case 2: s = max(s, 0.13)
            case 3: s = max(s, 0.07)
            default: s = max(s, 0.09)
            }
        case SKY_DARK: s = o.variant == 1 ? max(s, 0.12) : s
        case SKY_BLACKHOLE: s = 0.075
        case SKY_PULSAR: s = 0.07
        case SKY_ECHO: s = max(s, 0.11)
        default: break
        }
        return s * w / 2
    }

    func softness(_ o: SkyDSO) -> Double {
        switch o.kind {
        case SKY_GALAXY, SKY_CLUSTER: return 0.035
        case SKY_PN_RING, SKY_PN_BIPOLAR, SKY_BLACKHOLE, SKY_PULSAR: return 0.05
        case SKY_SNR: return 0.03
        case SKY_DARK: return 0.10
        default: return 0.07
        }
    }

    func deepSky(_ ctx: GraphicsContext) {
        for (i, o) in d.field.dsos.enumerated() {
            let R = radius(o)
            let seed = d.detailSeed &+ UInt64(i + 1) &* 0x9E37_79B9_7F4A_7C15
            var soft = ctx
            soft.addFilter(.blur(radius: max(0.5, R * softness(o))))
            soft.blendMode = (o.kind == SKY_DARK || !dark) ? .normal : .screen
            soft.drawLayer { l in
                var rng = SeededRandom(seed: seed)
                self.paint(l, o, R, 0, &rng)
            }
            var sharp = ctx
            sharp.blendMode = dark ? .screen : .normal
            sharp.drawLayer { l in
                var rng = SeededRandom(seed: seed)
                self.paint(l, o, R, 1, &rng)
            }
        }
    }

    /// pass 0 is the soft, blurred glow; pass 1 the crisp detail (stars, knots, filaments).
    func paint(_ l: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        var k = l
        let c = pt(o.p)
        k.translateBy(x: c.x, y: c.y)
        switch o.kind {
        case SKY_EMISSION: emission(k, o, R, pass, &rng)
        case SKY_PILLARS: pillars(k, o, R, pass, &rng)
        case SKY_TRIFID: trifid(k, o, R, pass, &rng)
        case SKY_ROSETTE: rosette(k, o, R, pass, &rng)
        case SKY_REFLECTION: reflection(k, o, R, pass, &rng)
        case SKY_PN_RING: planetary(k, o, R, pass, &rng)
        case SKY_PN_BIPOLAR: bipolar(k, o, R, pass, &rng)
        case SKY_SNR: remnant(k, o, R, pass, &rng)
        case SKY_GALAXY: galaxy(k, o, R, pass, &rng)
        case SKY_CLUSTER: cluster(k, o, R, pass, &rng)
        case SKY_DARK: darkNebula(k, o, R, pass, &rng)
        case SKY_COMPLEX: complexCloud(k, o, R, pass)
        case SKY_BLACKHOLE:
            if pass == 0 && o.variant == 0 { glow(k, .zero, R * 1.4, (1.0, 0.55, 0.25), 0.18) }
        case SKY_PULSAR:
            if pass == 0 { glow(k, .zero, R * 1.2, (0.55, 0.7, 1.0), 0.14) }
        case SKY_ECHO:
            if pass == 0 { glow(k, .zero, R, (0.85, 0.55, 0.4), 0.16) }
        default:
            if pass == 0 { glow(k, .zero, R, SkyInk.hAlpha, 0.3) }
        }
    }

    // Emission nebulae: hydrogen clouds lit red by hot young stars inside them.

    func emission(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        switch o.variant {
        case 1: compactNebula(k, o, R, pass, &rng)
        case 2: northAmerica(k, R, pass, &rng)
        case 3: california(k, o, R, pass, &rng)
        case 4: tarantula(k, R, pass, &rng)
        default:
            if o.name.contains("Orion") { orionNebula(k, R, pass, &rng) }
            else if o.name.contains("Lagoon") { lagoon(k, o, R, pass, &rng) }
            else if o.name.contains("Carina") { carina(k, o, R, pass, &rng) }
            else {
                var r = k
                r.rotate(by: .radians(o.angle))
                if pass == 0 {
                    cloud(r, R, o.ratio, 12, [SkyInk.hAlpha, SkyInk.magenta], 0.28, &rng)
                    glow(r, .zero, R * 0.4, (1.0, 0.75, 0.75), 0.25)
                }
            }
        }
    }

    /// M42: a teal heart of doubly ionised oxygen around the Trapezium, red wings sweeping south,
    /// M43 to the north across the dark Fish's Mouth.
    func orionNebula(_ k: GraphicsContext, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        let core = CGPoint(x: 0, y: -0.12 * R)
        if pass == 0 {
            cloud(k, R, 0.95, 9, [SkyInk.hAlpha, SkyInk.magenta, SkyInk.hAlpha], 0.26, &rng, spread: 0.55,
                  offset: CGPoint(x: 0, y: 0.1 * R))
            for s in [-1.0, 1.0] {
                let wing = [CGPoint(x: 0.05 * s * R, y: -0.1 * R), CGPoint(x: 0.45 * s * R, y: 0.15 * R),
                            CGPoint(x: 0.85 * s * R, y: 0.55 * R), CGPoint(x: 0.7 * s * R, y: 0.95 * R)]
                k.stroke(CV.curve(wing), with: .color(neb(SkyInk.hAlpha, 0.3)),
                         style: StrokeStyle(lineWidth: R * 0.28, lineCap: .round, lineJoin: .round))
            }
            glow(k, core, R * 0.55, SkyInk.oxygen, 0.42)
            glow(k, core, R * 0.25, (0.95, 1.0, 0.92), 0.55)
            glow(k, CGPoint(x: 0.08 * R, y: -0.78 * R), R * 0.26, SkyInk.hAlpha, 0.36)
            lane(k, [CGPoint(x: -0.75 * R, y: -0.55 * R), CGPoint(x: -0.3 * R, y: -0.42 * R),
                     CGPoint(x: -0.02 * R, y: -0.4 * R)], R * 0.2, 0.75)
        } else {
            let trapezium: [(Double, Double)] = [(-0.05, -0.03), (0.06, -0.05), (0.02, 0.05), (-0.07, 0.04)]
            for (x, y) in trapezium {
                dot(k, CGPoint(x: Double(core.x) + x * R, y: Double(core.y) + y * R), max(0.45, R * 0.03), (0.85, 0.9, 1.0), 0.9)
            }
        }
    }

    func lagoon(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        var r = k
        r.rotate(by: .radians(o.angle))
        let h = max(0.3, o.ratio)
        if pass == 0 {
            cloud(r, R, h, 12, [SkyInk.hAlpha, SkyInk.magenta, (1.0, 0.5, 0.5)], 0.28, &rng, spread: 0.6)
            glow(r, CGPoint(x: 0.25 * R, y: 0), R * 0.3, (1.0, 0.85, 0.8), 0.4)          // the Hourglass
            lane(r, [CGPoint(x: -0.1 * R, y: -0.5 * R * h), CGPoint(x: 0, y: 0),
                     CGPoint(x: -0.05 * R, y: 0.55 * R * h)], R * 0.12, 0.65)              // the lagoon itself
        } else {
            for _ in 0..<9 {                                                              // NGC 6530
                let p = CGPoint(x: -0.45 * R + rng.range(-0.25, 0.25) * R, y: rng.range(-0.3, 0.3) * R * h)
                dot(r, p, max(0.4, R * rng.range(0.015, 0.03)), SkyInk.hotStar, rng.range(0.5, 0.9))
            }
        }
    }

    func carina(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        var r = k
        r.rotate(by: .radians(o.angle))
        guard pass == 0 else { return }
        cloud(r, R, o.ratio, 16, [SkyInk.hAlpha, (1.0, 0.55, 0.4), SkyInk.magenta, (1.0, 0.75, 0.55)], 0.26, &rng, spread: 0.65)
        glow(r, .zero, R * 0.5, (1.0, 0.8, 0.65), 0.25)
        // the Keyhole, a dark V of dust beside Eta Carinae, and the broad lane across the nebula
        lane(r, [CGPoint(x: -0.3 * R, y: -0.25 * R), CGPoint(x: 0, y: 0.05 * R), CGPoint(x: 0.28 * R, y: -0.22 * R)], R * 0.1, 0.7)
        lane(r, [CGPoint(x: -0.9 * R, y: 0.4 * R), CGPoint(x: -0.4 * R, y: 0.25 * R), CGPoint(x: 0.1 * R, y: 0.5 * R)], R * 0.16, 0.55)
    }

    /// NGC 281 (Pacman), IC 405 (Flaming Star), IC 1396 (Elephant's Trunk).
    func compactNebula(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        if o.name.contains("Pacman") {
            let mouth = CGPoint(x: 0.05 * R, y: 0.05 * R)
            if pass == 0 {
                glow(k, .zero, R, SkyInk.hAlpha, 0.5)
                glow(k, .zero, R * 0.6, SkyInk.magenta, 0.35)
                var e = k
                e.blendMode = .destinationOut
                var wedge = Path()
                wedge.move(to: mouth)
                wedge.addArc(center: mouth, radius: R * 1.1, startAngle: .degrees(-10), endAngle: .degrees(48), clockwise: false)
                wedge.closeSubpath()
                e.fill(wedge, with: .color(Color.black.opacity(0.8)))
                lane(k, [CGPoint(x: -0.9 * R, y: 0.45 * R), CGPoint(x: -0.3 * R, y: 0.3 * R), CGPoint(x: 0.1 * R, y: 0.5 * R)], R * 0.18, 0.6)
            } else {
                dot(k, CGPoint(x: -0.1 * R, y: -0.05 * R), max(0.5, R * 0.035), SkyInk.hotStar, 0.9)
            }
        } else if o.name.contains("Flaming") {
            if pass == 0 {
                cloud(k, R, 1, 8, [SkyInk.hAlpha, (1.0, 0.45, 0.4)], 0.3, &rng, spread: 0.55)
                cloud(k, R, 1, 5, [SkyInk.dust], 0.22, &rng, spread: 0.4)
                for i in 0..<7 {
                    let a = Double(i) / 7 * CV.tau + rng.range(-0.3, 0.3)
                    var pts: [CGPoint] = []
                    for j in 0..<5 {
                        let rr = R * (0.15 + Double(j) * 0.2)
                        let bend = a + Double(j) * 0.18
                        pts.append(CGPoint(x: cos(bend) * rr, y: sin(bend) * rr))
                    }
                    k.stroke(CV.curve(pts), with: .color(neb(SkyInk.hAlpha, 0.22)),
                             style: StrokeStyle(lineWidth: R * 0.09, lineCap: .round))
                }
            } else {
                dot(k, .zero, max(0.5, R * 0.035), SkyInk.hotStar, 0.9)                 // AE Aurigae, a runaway star
            }
        } else {
            if pass == 0 {
                glow(k, .zero, R, SkyInk.hAlpha, 0.36)
                cloud(k, R, 1, 10, [SkyInk.hAlpha, SkyInk.magenta], 0.2, &rng, spread: 0.6)
                // the trunk: a dark globule winding in from the rim, its edge lit by the central star
                let trunk = [CGPoint(x: 0.95 * R, y: -0.15 * R), CGPoint(x: 0.6 * R, y: -0.1 * R), CGPoint(x: 0.42 * R, y: 0.12 * R),
                             CGPoint(x: 0.28 * R, y: 0.02 * R), CGPoint(x: 0.22 * R, y: -0.08 * R)]
                lane(k, trunk, R * 0.11, 0.8)
                let rim = trunk.map { CGPoint(x: Double($0.x) - R * 0.05, y: Double($0.y) - R * 0.04) }
                k.stroke(CV.curve(rim), with: .color(neb((1.0, 0.8, 0.75), 0.35)),
                         style: StrokeStyle(lineWidth: max(0.4, R * 0.025), lineCap: .round))
            } else {
                dot(k, .zero, max(0.5, R * 0.03), SkyInk.hotStar, 0.85)
            }
        }
    }

    /// NGC 7000 looks like the continent; the dark "Gulf of Mexico" is dust (LDN 935),
    /// with the Pelican Nebula beyond it to the west.
    func northAmerica(_ k: GraphicsContext, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        guard pass == 0 else { return }
        let outline: [(Double, Double)] = [
            (-0.95, -0.55), (-0.62, -0.78), (-0.2, -0.86), (0.22, -0.92), (0.52, -0.72), (0.72, -0.46), (0.58, -0.26),
            (0.5, 0.0), (0.56, 0.24), (0.62, 0.44), (0.5, 0.46), (0.42, 0.26), (0.2, 0.22), (0.02, 0.3), (0.06, 0.52),
            (0.24, 0.6), (0.18, 0.76), (0.04, 0.92), (-0.08, 0.86), (-0.26, 0.6), (-0.46, 0.26), (-0.6, 0.0), (-0.76, -0.3),
        ]
        let pts = outline.map { CGPoint(x: $0.0 * R, y: $0.1 * R * 0.85) }
        k.fill(CV.curve(pts, closed: true), with: .color(neb(SkyInk.hAlpha, 0.34)))
        cloud(k, R * 0.8, 0.8, 8, [SkyInk.hAlpha, SkyInk.magenta], 0.22, &rng, spread: 0.5)
        // the Cygnus Wall, the bright ridge along "Mexico" and "Central America"
        let wall = [CGPoint(x: -0.12 * R, y: 0.68 * R), CGPoint(x: 0.04 * R, y: 0.51 * R), CGPoint(x: 0.22 * R, y: 0.43 * R)]
        k.stroke(CV.curve(wall), with: .color(neb((1.0, 0.6, 0.62), 0.5)),
                 style: StrokeStyle(lineWidth: R * 0.08, lineCap: .round))
        glow(k, CGPoint(x: 1.35 * R, y: 0.05 * R), R * 0.5, SkyInk.hAlpha, 0.28)                // the Pelican
    }

    func california(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        var r = k
        r.rotate(by: .radians(o.angle))
        let h = R * max(0.2, o.ratio)
        if pass == 0 {
            for i in 0..<4 {
                var pts: [CGPoint] = []
                let off = rng.range(-0.5, 0.5) * h
                for j in 0...8 {
                    let x = -R + Double(j) / 8 * 2 * R
                    let y = off + sin(Double(j) * 0.9 + Double(i)) * h * 0.35
                    pts.append(CGPoint(x: x, y: y))
                }
                r.stroke(CV.curve(pts), with: .color(neb(SkyInk.hAlpha, 0.26)),
                         style: StrokeStyle(lineWidth: h * rng.range(0.5, 1.0), lineCap: .round, lineJoin: .round))
            }
            eglow(r, .zero, R, h * 1.2, 0, SkyInk.hAlpha, 0.25)
        } else {
            var pts: [CGPoint] = []                      // the sharp, bright "coastline"
            for j in 0...10 {
                let x = -R * 0.9 + Double(j) / 10 * 1.8 * R
                pts.append(CGPoint(x: x, y: -h * 0.55 + sin(Double(j) * 1.3) * h * 0.12))
            }
            r.stroke(CV.curve(pts), with: .color(neb((1.0, 0.55, 0.6), 0.35)),
                     style: StrokeStyle(lineWidth: max(0.5, h * 0.12), lineCap: .round))
        }
    }

    func tarantula(_ k: GraphicsContext, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        if pass == 0 {
            glow(k, .zero, R, SkyInk.magenta, 0.35)
            glow(k, .zero, R * 0.45, (1.0, 0.7, 0.85), 0.4)
            for i in 0..<9 {
                let a = Double(i) / 9 * CV.tau + rng.range(-0.25, 0.25)
                let bend = rng.range(-0.8, 0.8)
                var pts: [CGPoint] = []
                for j in 0...4 {
                    let rr = R * (0.15 + Double(j) * 0.2)
                    let aa = a + bend * Double(j) * 0.15
                    pts.append(CGPoint(x: cos(aa) * rr, y: sin(aa) * rr))
                }
                k.stroke(CV.curve(pts), with: .color(neb(SkyInk.hAlpha, 0.3)),
                         style: StrokeStyle(lineWidth: R * 0.07, lineCap: .round))
            }
        } else {
            dot(k, .zero, max(0.6, R * 0.05), (0.85, 0.9, 1.0), 0.95)                   // R136, the most massive stars known
        }
    }

    /// The Pillars of Creation: columns of cold gas and dust, tips lit and eroded by the cluster NGC 6611.
    static let pillarTable: [(x: Double, h: Double, w: Double, lean: Double)] = [
        (-0.42, 0.95, 0.2, 0.12), (0.02, 0.62, 0.15, 0.06), (0.38, 0.45, 0.12, -0.04),
    ]

    func pillarTip(_ c: (x: Double, h: Double, w: Double, lean: Double), _ R: Double) -> CGPoint {
        CGPoint(x: (c.x + c.lean) * R, y: 1.05 * R - c.h * 1.7 * R)
    }

    func column(_ base: CGPoint, _ tip: CGPoint, _ width: Double) -> Path {
        var p = Path()
        let bw = width / 2, tw = width * 0.32
        let bx = Double(base.x), by = Double(base.y), tx = Double(tip.x), ty = Double(tip.y)
        let midY = (by + ty) / 2
        p.move(to: CGPoint(x: bx - bw, y: by))
        p.addQuadCurve(to: CGPoint(x: tx - tw, y: ty + tw), control: CGPoint(x: bx - bw * 0.7, y: midY))
        p.addQuadCurve(to: CGPoint(x: tx + tw, y: ty + tw), control: CGPoint(x: tx, y: ty - tw))
        p.addQuadCurve(to: CGPoint(x: bx + bw, y: by), control: CGPoint(x: bx + bw * 0.8, y: midY))
        p.closeSubpath()
        return p
    }

    func pillars(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        if pass == 0 {
            cloud(k, R, 0.9, 12, [SkyInk.hAlpha, (1.0, 0.62, 0.42), SkyInk.oxygen], 0.24, &rng, spread: 0.6)
            glow(k, CGPoint(x: 0.1 * R, y: -0.35 * R), R * 0.5, (1.0, 0.82, 0.6), 0.3)
            for c in CoverPainter.pillarTable {
                let base = CGPoint(x: c.x * R, y: 1.05 * R)
                let col = column(base, pillarTip(c, R), c.w * 2 * R)
                var e = k
                e.blendMode = .destinationOut
                e.fill(col, with: .color(Color.black.opacity(0.88)))
                k.stroke(col, with: .color(neb((1.0, 0.86, 0.62), 0.32)), lineWidth: max(0.5, R * 0.025))
            }
        } else {
            for _ in 0..<7 {
                let p = CGPoint(x: rng.range(-0.6, 0.7) * R, y: rng.range(-0.95, -0.4) * R)
                dot(k, p, max(0.4, R * rng.range(0.015, 0.03)), SkyInk.hotStar, rng.range(0.5, 0.9))
            }
        }
    }

    /// M20: a red emission sphere cut into three lobes by dust, a blue reflection nebula to the north.
    func trifid(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        let c = CGPoint(x: 0, y: 0.05 * R)
        if pass == 0 {
            glow(k, CGPoint(x: 0, y: -1.05 * R), R * 0.85, SkyInk.dust, 0.42)
            glow(k, c, R * 0.95, SkyInk.hAlpha, 0.5)
            glow(k, c, R * 0.5, SkyInk.magenta, 0.3)
            for deg in [100.0, 215.0, 330.0] {
                let a = deg * Double.pi / 180
                lane(k, [c, CGPoint(x: cos(a) * 0.55 * R, y: 0.05 * R + sin(a) * 0.55 * R),
                         CGPoint(x: cos(a + 0.15) * R, y: 0.05 * R + sin(a + 0.15) * R)], R * 0.1, 0.8)
            }
        } else {
            dot(k, c, max(0.5, R * 0.04), SkyInk.hotStar, 0.9)
        }
    }

    /// The Rosette: a hollow blown in the cloud by the winds of its central cluster NGC 2244.
    func rosette(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        if pass == 0 {
            let g = Gradient(stops: [
                .init(color: neb(SkyInk.hAlpha, 0), location: 0),
                .init(color: neb(SkyInk.hAlpha, 0.04), location: 0.3),
                .init(color: neb(SkyInk.hAlpha, 0.5), location: 0.55),
                .init(color: neb(SkyInk.magenta, 0.35), location: 0.78),
                .init(color: neb(SkyInk.hAlpha, 0), location: 1),
            ])
            k.fill(CV.circle(.zero, R), with: .radialGradient(g, center: .zero, startRadius: 0, endRadius: R))
            for _ in 0..<14 {
                let a = rng.range(0, CV.tau), rr = R * rng.range(0.5, 0.85)
                glow(k, CGPoint(x: cos(a) * rr, y: sin(a) * rr), R * rng.range(0.15, 0.3), SkyInk.hAlpha, 0.25)
            }
            for _ in 0..<7 {                                       // dark globules pointing at the cluster
                let a = rng.range(0, CV.tau), r0 = R * rng.range(0.42, 0.62)
                lane(k, [CGPoint(x: cos(a) * r0, y: sin(a) * r0),
                         CGPoint(x: cos(a) * (r0 + R * 0.12), y: sin(a) * (r0 + R * 0.12))], R * 0.05, 0.6)
            }
        } else {
            for _ in 0..<8 {
                let a = rng.range(0, CV.tau), rr = R * rng.range(0, 0.3)
                dot(k, CGPoint(x: cos(a) * rr, y: sin(a) * rr), max(0.4, R * rng.range(0.015, 0.03)), SkyInk.hotStar, rng.range(0.6, 0.95))
            }
        }
    }

    /// Reflection nebulae: dust scattering the blue light of nearby stars.
    func reflection(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        if o.variant == 1 {
            // The Pleiades are drifting through an unrelated dust cloud that their light turns blue.
            guard pass == 0 else { return }
            for s in d.field.stars where s.mag < 5.2 {
                let dx = Double(s.p.x - o.p.x) * w, dy = Double(s.p.y - o.p.y) * w
                if (dx * dx + dy * dy).squareRoot() < R * 1.1 {
                    glow(k, CGPoint(x: dx, y: dy), R * (0.12 + 0.07 * max(0, 5.2 - s.mag)), SkyInk.dust, 0.32)
                }
            }
            var r = k
            r.rotate(by: .radians(-0.55))
            for i in 0..<10 {                                     // the fine streaks of the Merope nebula
                let y = (Double(i) / 9 - 0.5) * 1.4 * R
                let len = R * rng.range(0.5, 0.95)
                let x0 = rng.range(-0.4, 0.1) * R
                var p = Path()
                p.move(to: CGPoint(x: x0, y: y))
                p.addLine(to: CGPoint(x: x0 + len, y: y + rng.range(-0.05, 0.05) * R))
                r.stroke(p, with: .color(neb(SkyInk.dust, 0.12)), style: StrokeStyle(lineWidth: max(0.4, R * 0.03), lineCap: .round))
            }
        } else {
            // The Witch Head: a wisp of dust lit by Rigel
            guard pass == 0 else { return }
            var r = k
            r.rotate(by: .radians(o.angle))
            let h = R * max(0.35, o.ratio)
            for i in 0..<6 {
                var pts: [CGPoint] = []
                let off = (Double(i) / 5 - 0.5) * h * 1.2
                for j in 0...7 {
                    let x = -R + Double(j) / 7 * 2 * R
                    let chin = j > 5 ? -h * 0.3 : 0
                    pts.append(CGPoint(x: x, y: off + sin(Double(j) * 1.1 + Double(i) * 0.7) * h * 0.25 + chin))
                }
                r.stroke(CV.curve(pts), with: .color(neb(SkyInk.dust, 0.2)),
                         style: StrokeStyle(lineWidth: h * rng.range(0.25, 0.5), lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Planetary nebulae: the shed outer layers of dying Sun-like stars, lit by the exposed white dwarf.
    func planetary(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        var r = k
        r.rotate(by: .radians(o.angle))
        switch o.variant {
        case 1:   // Eskimo: an inner bubble inside a "parka" of comet-shaped knots
            if pass == 0 {
                glow(r, .zero, R * 0.55, SkyInk.oxygen, 0.55)
                glow(r, .zero, R * 0.3, (0.85, 0.95, 1.0), 0.5)
                ring(r, .zero, R * 0.6, R * 0.98, .color(neb((1.0, 0.6, 0.5), 0.18)))
            } else {
                for i in 0..<40 {
                    let a = Double(i) / 40 * CV.tau + rng.range(-0.05, 0.05)
                    let r0 = R * rng.range(0.6, 0.72), r1 = r0 + R * rng.range(0.12, 0.28)
                    var p = Path()
                    p.move(to: CGPoint(x: cos(a) * r0, y: sin(a) * r0))
                    p.addLine(to: CGPoint(x: cos(a) * r1, y: sin(a) * r1))
                    r.stroke(p, with: .color(neb((1.0, 0.62, 0.5), 0.3)), style: StrokeStyle(lineWidth: max(0.35, R * 0.03), lineCap: .round))
                }
                dot(r, .zero, max(0.4, R * 0.04), SkyInk.white, 0.95)
            }
        case 2:   // Cat's Eye: concentric shells around overlapping inner bubbles
            if pass == 0 {
                for i in 0..<5 {
                    let rr = R * (0.5 + Double(i) * 0.12)
                    r.stroke(CV.circle(.zero, rr), with: .color(neb(SkyInk.hAlpha, 0.16 - Double(i) * 0.02)), lineWidth: max(0.4, R * 0.03))
                }
                eglow(r, .zero, R * 0.42, R * 0.22, 0.4, SkyInk.oxygen, 0.6)
                eglow(r, .zero, R * 0.4, R * 0.2, -0.45, SkyInk.oxygen, 0.5)
            } else {
                var e1 = r
                e1.rotate(by: .radians(0.4))
                e1.stroke(Path(ellipseIn: CGRect(x: -R * 0.42, y: -R * 0.2, width: R * 0.84, height: R * 0.4)),
                          with: .color(neb(SkyInk.hAlpha, 0.45)), lineWidth: max(0.4, R * 0.035))
                var e2 = r
                e2.rotate(by: .radians(-0.45))
                e2.stroke(Path(ellipseIn: CGRect(x: -R * 0.4, y: -R * 0.19, width: R * 0.8, height: R * 0.38)),
                          with: .color(neb(SkyInk.hAlpha, 0.35)), lineWidth: max(0.4, R * 0.03))
                dot(r, .zero, max(0.4, R * 0.04), SkyInk.white, 0.95)
            }
        case 3:   // Helix: the Eye of God, its inner edge fringed with thousands of cometary knots
            if pass == 0 {
                glow(r, .zero, R * 0.55, SkyInk.oxygen, 0.3)
                ring(r, .zero, R * 0.45, R, .radialGradient(Gradient(stops: [
                    .init(color: neb(SkyInk.oxygen, 0), location: 0.4),
                    .init(color: neb(SkyInk.oxygen, 0.35), location: 0.52),
                    .init(color: neb((1.0, 0.55, 0.4), 0.45), location: 0.72),
                    .init(color: neb(SkyInk.hAlpha, 0.35), location: 0.88),
                    .init(color: neb(SkyInk.hAlpha, 0), location: 1),
                ]), center: .zero, startRadius: 0, endRadius: R))
                var e = r
                e.rotate(by: .radians(0.6))
                e.scaleBy(x: 1, y: 0.85)
                e.stroke(CV.circle(CGPoint(x: R * 0.08, y: 0), R * 0.86), with: .color(neb(SkyInk.hAlpha, 0.18)), lineWidth: R * 0.12)
            } else {
                for _ in 0..<70 {
                    let a = rng.range(0, CV.tau), r0 = R * rng.range(0.45, 0.62)
                    var p = Path()
                    p.move(to: CGPoint(x: cos(a) * r0, y: sin(a) * r0))
                    p.addLine(to: CGPoint(x: cos(a) * (r0 + R * 0.06), y: sin(a) * (r0 + R * 0.06)))
                    r.stroke(p, with: .color(neb((1.0, 0.7, 0.5), 0.35)), style: StrokeStyle(lineWidth: max(0.3, R * 0.018), lineCap: .round))
                }
                dot(r, .zero, max(0.4, R * 0.035), (0.85, 0.9, 1.0), 0.95)
            }
        default:  // M57, the Ring: blue-green oxygen inside, red hydrogen outside
            var e = r
            e.scaleBy(x: 1, y: 0.78)
            if pass == 0 {
                e.fill(CV.circle(.zero, R * 1.25), with: .radialGradient(Gradient(colors: [neb(SkyInk.hAlpha, 0.12), neb(SkyInk.hAlpha, 0)]),
                                                                          center: .zero, startRadius: R * 0.8, endRadius: R * 1.25))
                e.fill(CV.circle(.zero, R), with: .radialGradient(Gradient(stops: [
                    .init(color: neb(SkyInk.dust, 0.18), location: 0),
                    .init(color: neb(SkyInk.oxygen, 0.3), location: 0.42),
                    .init(color: neb((0.75, 1.0, 0.6), 0.55), location: 0.58),
                    .init(color: neb((1.0, 0.55, 0.35), 0.6), location: 0.76),
                    .init(color: neb(SkyInk.hAlpha, 0.45), location: 0.9),
                    .init(color: neb(SkyInk.hAlpha, 0), location: 1),
                ]), center: .zero, startRadius: 0, endRadius: R))
            } else {
                dot(e, .zero, max(0.35, R * 0.03), SkyInk.white, 0.8)
            }
        }
    }

    /// M27, the Dumbbell: a bright "apple core" inside a fainter football-shaped shell.
    func bipolar(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        var r = k
        r.rotate(by: .radians(o.angle))
        let h = R * max(0.5, o.ratio)
        if pass == 0 {
            eglow(r, .zero, R, h * 1.05, 0, SkyInk.hAlpha, 0.3)
            var lobes = Path()
            for s in [-1.0, 1.0] {
                lobes.move(to: CGPoint(x: 0, y: -h * 0.28))
                lobes.addQuadCurve(to: CGPoint(x: s * R * 0.92, y: -h * 0.62), control: CGPoint(x: s * R * 0.45, y: -h * 0.2))
                lobes.addQuadCurve(to: CGPoint(x: s * R * 0.92, y: h * 0.62), control: CGPoint(x: s * R * 1.12, y: 0))
                lobes.addQuadCurve(to: CGPoint(x: 0, y: h * 0.28), control: CGPoint(x: s * R * 0.45, y: h * 0.2))
                lobes.closeSubpath()
            }
            r.fill(lobes, with: .color(neb(SkyInk.oxygen, 0.42)))
            r.stroke(lobes, with: .color(neb(SkyInk.hAlpha, 0.4)), lineWidth: R * 0.1)
        } else {
            dot(r, .zero, max(0.35, R * 0.03), SkyInk.white, 0.85)
        }
    }

    /// Supernova remnants: debris of exploded stars.
    func remnant(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        switch o.variant {
        case 0:   // the Crab: blue synchrotron haze from the pulsar's wind inside a cage of red filaments
            var r = k
            r.rotate(by: .radians(o.angle))
            let h = R * max(0.6, o.ratio)
            if pass == 0 {
                eglow(r, .zero, R * 0.9, h * 0.9, 0, (0.6, 0.72, 1.0), 0.45)
            } else {
                for _ in 0..<26 {
                    var pts: [CGPoint] = []
                    let a = rng.range(0, CV.tau), rr = rng.range(0.25, 0.9)
                    var x = cos(a) * rr * R, y = sin(a) * rr * h
                    for _ in 0..<4 {
                        pts.append(CGPoint(x: x, y: y))
                        x += rng.range(-0.22, 0.22) * R
                        y += rng.range(-0.22, 0.22) * h
                    }
                    r.stroke(CV.curve(pts), with: .color(neb((1.0, 0.48, 0.32), 0.42)),
                             style: StrokeStyle(lineWidth: max(0.35, R * 0.035), lineCap: .round, lineJoin: .round))
                }
            }
        case 2:   // filament arcs: oxygen-teal and hydrogen-red side by side
            if o.name.contains("Veil") {
                arcs(k, R, from: 100, to: 250, count: 4, pass: pass, &rng)       // the Eastern Veil
                arcs(k, R, from: -60, to: 40, count: 4, pass: pass, &rng)        // the Western Veil
                arcs(k, R * 0.75, from: 160, to: 230, count: 2, pass: pass, &rng) // Pickering's Triangle
            } else {
                for _ in 0..<7 {
                    let a0 = rng.range(0, 360)
                    let a1 = a0 + rng.range(40, 110)
                    let rr = R * rng.range(0.4, 1.0)
                    arcs(k, rr, from: a0, to: a1, count: 2, pass: pass, &rng)
                }
            }
        default:  // a shell
            if o.name.contains("1006") {
                // faint, but bright on two opposite limbs where the shock meets the magnetic field
                arcs(k, R * 0.9, from: 120, to: 200, count: 3, pass: pass, &rng)
                arcs(k, R * 0.9, from: -60, to: 20, count: 3, pass: pass, &rng)
                if pass == 0 { k.stroke(CV.circle(.zero, R * 0.9), with: .color(neb(SkyInk.hAlpha, 0.08)), lineWidth: R * 0.1) }
            } else {
                if pass == 0 { glow(k, .zero, R, (0.55, 0.65, 1.0), 0.16) }
                let cols: [RGB01] = [SkyInk.oxygen, SkyInk.hAlpha, (0.7, 0.5, 1.0), (1.0, 0.75, 0.5)]
                for i in 0..<34 {
                    let a = Double(i) / 34 * CV.tau + rng.range(-0.1, 0.1)
                    let rr = R * rng.range(0.62, 0.82)
                    let c = cols[rng.pick(cols.count)]
                    let p = CGPoint(x: cos(a) * rr, y: sin(a) * rr)
                    if pass == 0 { glow(k, p, R * 0.18, c, 0.35) } else { dot(k, p, max(0.35, R * 0.025), c, 0.6) }
                }
            }
        }
    }

    func arcs(_ k: GraphicsContext, _ R: Double, from a0: Double, to a1: Double, count: Int, pass: Int, _ rng: inout SeededRandom) {
        for i in 0..<count {
            let teal = i % 2 == 0
            let offset = (teal ? 0.03 : -0.02) * R + rng.range(-0.04, 0.04) * R
            let phase = rng.range(0, CV.tau)
            var pts: [CGPoint] = []
            let n = 18
            for j in 0...n {
                let a = (a0 + (a1 - a0) * Double(j) / Double(n)) * Double.pi / 180
                let rr = R + offset + sin(Double(j) * 0.8 + phase) * R * 0.035
                pts.append(CGPoint(x: cos(a) * rr, y: -sin(a) * rr))
            }
            let col = teal ? SkyInk.oxygen : SkyInk.hAlpha
            let lw = pass == 0 ? R * 0.07 : max(0.35, R * 0.015)
            k.stroke(CV.curve(pts), with: .color(neb(col, pass == 0 ? 0.3 : 0.45)),
                     style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        }
    }

    // Galaxies

    func galaxy(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        switch o.variant {
        case 1: edgeOn(k, R, o.angle, max(0.15, o.ratio), pass)
        case 2: sombrero(k, o, R, pass)
        case 3: jetGalaxy(k, o, R, pass)
        case 4: centaurusA(k, o, R, pass)
        case 5: cigar(k, o, R, pass, &rng)
        case 6: magellanic(k, o, R, pass, &rng)
        case 7:
            if o.name.contains("Antennae") { antennae(k, R, pass, &rng) } else { whirlpool(k, o, R, pass, &rng) }
        case 8: group(k, o, R, pass, &rng)
        default:
            if o.name.contains("M31") {
                spiral(k, R, angle: o.angle, ratio: o.ratio, pass, &rng, pitch: 0.16)
                if pass == 0 {   // M32 to the south, M110 to the north-west
                    eglow(k, CGPoint(x: 0.04 * R, y: 0.3 * R), R * 0.09, R * 0.075, 0, SkyInk.warm, 0.55)
                    eglow(k, CGPoint(x: 0.3 * R, y: -0.34 * R), R * 0.13, R * 0.08, -0.6, SkyInk.warm, 0.4)
                }
            } else if o.name.contains("M33") {
                spiral(k, R, angle: o.angle, ratio: o.ratio, pass, &rng, pitch: 0.3, knots: 2.4)
            } else if o.name.contains("M101") {
                spiral(k, R, angle: o.angle, ratio: o.ratio, pass, &rng, arms: 4, pitch: 0.26, knots: 1.5)
            } else if o.name.contains("M77") {
                spiral(k, R * 0.8, angle: o.angle, ratio: o.ratio, pass, &rng, pitch: 0.2)
                if pass == 0 { glow(k, .zero, R * 0.25, (1.0, 0.95, 0.85), 0.7) }    // a Seyfert nucleus
            } else {
                spiral(k, R, angle: o.angle, ratio: o.ratio, pass, &rng)
            }
        }
    }

    /// A spiral galaxy at its real tilt (axis ratio) and position angle.
    func spiral(_ k: GraphicsContext, _ R: Double, angle: Double, ratio: Double, _ pass: Int, _ rng: inout SeededRandom,
                arms: Int = 2, pitch: Double = 0.24, knots: Double = 1) {
        var r = k
        r.rotate(by: .radians(angle))
        r.scaleBy(x: 1, y: max(0.12, ratio))
        let sense: Double = rng.unit() < 0.5 ? 1 : -1
        let twist = rng.range(0, CV.tau)
        if pass == 0 {
            glow(r, .zero, R, (0.78, 0.84, 1.0), 0.28)                       // disc of young blue stars
            for a in 0..<arms {
                let base = twist + Double(a) * CV.tau / Double(arms)
                var pts: [CGPoint] = []
                for j in 0..<44 {
                    let th = Double(j) * 0.16
                    let rr = R * 0.14 * exp(pitch * th * 1.35)
                    if rr > R * 1.02 { break }
                    let ang = base + sense * th
                    pts.append(CGPoint(x: cos(ang) * rr, y: sin(ang) * rr))
                }
                if pts.count > 2 {
                    r.stroke(CV.curve(pts), with: .color(neb((0.82, 0.88, 1.0), 0.32)),
                             style: StrokeStyle(lineWidth: R * 0.16, lineCap: .round, lineJoin: .round))
                    let inner = pts.map { CGPoint(x: Double($0.x) * 0.9, y: Double($0.y) * 0.9) }
                    lane(r, inner, R * 0.05, 0.45)                           // dust on the inner edge of each arm
                }
            }
            glow(r, .zero, R * 0.42, SkyInk.warm, 0.6)                       // the old yellow bulge
            glow(r, .zero, R * 0.16, (1.0, 0.96, 0.88), 0.85)
        } else {
            for a in 0..<arms {                                              // pink star-forming regions along the arms
                let base = twist + Double(a) * CV.tau / Double(arms)
                for _ in 0..<Int(7 * knots) {
                    let th = rng.range(0.6, 5.5)
                    let rr = R * 0.14 * exp(pitch * th * 1.35)
                    if rr > R { continue }
                    let ang = base + sense * th
                    dot(r, CGPoint(x: cos(ang) * rr, y: sin(ang) * rr), max(0.3, R * 0.022), SkyInk.magenta, 0.55)
                }
            }
            dot(r, .zero, max(0.4, R * 0.035), (1.0, 0.97, 0.9), 0.9)
        }
    }

    func edgeOn(_ k: GraphicsContext, _ R: Double, _ angle: Double, _ ratio: Double, _ pass: Int) {
        var r = k
        r.rotate(by: .radians(angle))
        if pass == 0 {
            eglow(r, .zero, R, R * ratio, 0, (0.88, 0.9, 1.0), 0.45)
            eglow(r, .zero, R * 0.35, R * ratio * 1.2, 0, SkyInk.warm, 0.55)
            lane(r, [CGPoint(x: -R * 0.9, y: R * ratio * 0.08), CGPoint(x: 0, y: R * ratio * 0.12),
                     CGPoint(x: R * 0.9, y: R * ratio * 0.08)], max(0.6, R * ratio * 0.22), 0.7)
        }
    }

    /// M104: a huge bulge with the dark dust lane of its disc crossing in front.
    func sombrero(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int) {
        var r = k
        r.rotate(by: .radians(o.angle))
        let h = R * max(0.3, o.ratio)
        if pass == 0 {
            eglow(r, .zero, R, h * 0.55, 0, (0.95, 0.92, 0.85), 0.42)
            eglow(r, .zero, R * 0.5, R * 0.42, 0, SkyInk.warm, 0.7)
            var front = Path()
            for i in 0...24 {
                let a = Double.pi * Double(i) / 24
                let q = CGPoint(x: cos(a) * R * 0.95, y: h * 0.06 + sin(a) * h * 0.17)
                if i == 0 { front.move(to: q) } else { front.addLine(to: q) }
            }
            var e = r
            e.blendMode = .destinationOut
            e.stroke(front, with: .color(Color.black.opacity(0.75)), style: StrokeStyle(lineWidth: max(0.6, h * 0.12), lineCap: .round))
        } else {
            dot(r, .zero, max(0.4, R * 0.04), (1.0, 0.95, 0.85), 0.9)
        }
    }

    /// M87: a giant elliptical galaxy firing a jet from its black hole (the first one ever imaged).
    func jetGalaxy(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int) {
        var r = k
        r.rotate(by: .radians(o.angle))
        if pass == 0 {
            eglow(r, .zero, R, R * max(0.6, o.ratio), 0, SkyInk.warm, 0.5)
            glow(r, .zero, R * 0.35, (1.0, 0.95, 0.85), 0.6)
            var p = Path()
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: R * 0.95, y: 0))
            r.stroke(p, with: .linearGradient(Gradient(colors: [neb((0.7, 0.82, 1.0), 0.55), neb((0.7, 0.82, 1.0), 0.05)]),
                                              startPoint: .zero, endPoint: CGPoint(x: R * 0.95, y: 0)),
                     style: StrokeStyle(lineWidth: max(0.6, R * 0.06), lineCap: .round))
        } else {
            dot(r, .zero, max(0.4, R * 0.04), (1.0, 0.97, 0.9), 0.95)
        }
    }

    /// Centaurus A: an elliptical galaxy that swallowed a spiral; its dust band is warped and edged with star birth.
    func centaurusA(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int) {
        var r = k
        r.rotate(by: .radians(o.angle))
        guard pass == 0 else { return }
        eglow(r, .zero, R, R * max(0.6, o.ratio), 0, SkyInk.warm, 0.5)
        glow(r, .zero, R * 0.3, (1.0, 0.94, 0.84), 0.55)
        let band = [CGPoint(x: -R * 0.95, y: R * 0.1), CGPoint(x: -R * 0.4, y: -R * 0.06),
                    CGPoint(x: R * 0.3, y: R * 0.08), CGPoint(x: R * 0.95, y: -R * 0.08)]
        lane(r, band, R * 0.2, 0.8)
        let edge = band.map { CGPoint(x: Double($0.x), y: Double($0.y) - R * 0.13) }
        r.stroke(CV.curve(edge), with: .color(neb(SkyInk.magenta, 0.25)), lineWidth: max(0.4, R * 0.04))
    }

    /// M82: an edge-on starburst galaxy blowing a wind of red hydrogen out of both faces of its disc.
    func cigar(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        var r = k
        r.rotate(by: .radians(o.angle))
        let h = R * max(0.25, o.ratio)
        guard pass == 0 else { return }
        eglow(r, .zero, R, h, 0, (0.95, 0.92, 0.84), 0.55)
        for i in 0..<5 {
            let x = (Double(i) / 4 - 0.5) * 1.3 * R
            lane(r, [CGPoint(x: x - R * 0.08, y: rng.range(-0.3, 0.3) * h), CGPoint(x: x + R * 0.08, y: rng.range(-0.3, 0.3) * h)], h * 0.35, 0.55)
        }
        for i in 0..<16 {
            let s: Double = i % 2 == 0 ? 1 : -1
            let x0 = rng.range(-0.25, 0.25) * R
            let spread = rng.range(-0.5, 0.5)
            let len = rng.range(0.6, 1.0) * R
            let pts = [CGPoint(x: x0, y: 0), CGPoint(x: x0 + spread * len * 0.4, y: s * len * 0.5), CGPoint(x: x0 + spread * len, y: s * len)]
            r.stroke(CV.curve(pts), with: .color(neb(SkyInk.hAlpha, 0.28)), style: StrokeStyle(lineWidth: max(0.5, R * 0.05), lineCap: .round))
        }
    }

    /// The Large Magellanic Cloud: a dwarf galaxy with an off-centre bar and pink star-forming regions.
    func magellanic(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        var r = k
        r.rotate(by: .radians(o.angle))
        let h = R * max(0.4, o.ratio)
        if pass == 0 {
            eglow(r, .zero, R, h, 0, (0.85, 0.88, 1.0), 0.3)
            eglow(r, CGPoint(x: -0.1 * R, y: 0.05 * h), R * 0.55, h * 0.3, 0.08, (1.0, 0.95, 0.88), 0.45)
            cloud(r, R, h / R, 10, [(0.85, 0.88, 1.0), (0.95, 0.92, 0.88)], 0.18, &rng, spread: 0.6, size: (0.15, 0.35))
            for _ in 0..<6 {
                glow(r, CGPoint(x: rng.range(-0.7, 0.7) * R, y: rng.range(-0.6, 0.6) * h), R * rng.range(0.05, 0.1), SkyInk.hAlpha, 0.45)
            }
        } else {
            var dots = Path()
            for _ in 0..<160 {
                let a = rng.range(0, CV.tau), rr = pow(rng.unit(), 0.7)
                let x = cos(a) * rr * R, y = sin(a) * rr * h
                let s = rng.range(0.25, 0.5)
                dots.addEllipse(in: CGRect(x: x - s, y: y - s, width: 2 * s, height: 2 * s))
            }
            r.fill(dots, with: .color(dark ? Color.white.opacity(0.35) : CoverPalette.rgb(pal.ink, 0.2)))
        }
    }

    /// M51 and its companion NGC 5195, which tugs on the end of one arm.
    func whirlpool(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        spiral(k, R * 0.78, angle: o.angle, ratio: o.ratio, pass, &rng, pitch: 0.22, knots: 1.6)
        let comp = CGPoint(x: 0.12 * R, y: -0.98 * R)
        if pass == 0 {
            var bridge = Path()
            bridge.move(to: CGPoint(x: 0.5 * R, y: -0.35 * R))
            bridge.addQuadCurve(to: comp, control: CGPoint(x: 0.55 * R, y: -0.8 * R))
            k.stroke(bridge, with: .color(neb((0.82, 0.88, 1.0), 0.25)), style: StrokeStyle(lineWidth: R * 0.1, lineCap: .round))
            glow(k, comp, R * 0.28, SkyInk.warm, 0.55)
            lane(k, [CGPoint(x: Double(comp.x) - R * 0.15, y: Double(comp.y) + R * 0.05),
                     CGPoint(x: Double(comp.x) + R * 0.12, y: Double(comp.y) - R * 0.02)], R * 0.05, 0.5)
        } else {
            dot(k, comp, max(0.4, R * 0.03), (1.0, 0.95, 0.85), 0.85)
        }
    }

    /// The Antennae: two galaxies in collision, flinging out two long tidal tails.
    func antennae(_ k: GraphicsContext, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        let a = CGPoint(x: -0.18 * R, y: -0.1 * R), b = CGPoint(x: 0.16 * R, y: 0.12 * R)
        if pass == 0 {
            let tail1 = [a, CGPoint(x: -0.6 * R, y: -0.5 * R), CGPoint(x: -0.4 * R, y: -1.2 * R), CGPoint(x: 0.1 * R, y: -1.5 * R)]
            let tail2 = [b, CGPoint(x: 0.6 * R, y: 0.45 * R), CGPoint(x: 0.45 * R, y: 1.15 * R), CGPoint(x: -0.05 * R, y: 1.45 * R)]
            for t in [tail1, tail2] {
                k.stroke(CV.curve(t), with: .color(neb((0.82, 0.88, 1.0), 0.22)),
                         style: StrokeStyle(lineWidth: R * 0.14, lineCap: .round, lineJoin: .round))
            }
            glow(k, a, R * 0.38, (1.0, 0.86, 0.7), 0.5)
            glow(k, b, R * 0.34, (1.0, 0.86, 0.7), 0.5)
            lane(k, [CGPoint(x: -0.3 * R, y: 0.12 * R), CGPoint(x: 0, y: 0), CGPoint(x: 0.25 * R, y: -0.1 * R)], R * 0.08, 0.6)
            cloud(k, R * 0.5, 1, 6, [SkyInk.magenta, (0.7, 0.8, 1.0)], 0.35, &rng, spread: 0.6, size: (0.08, 0.16))
        } else {
            dot(k, a, max(0.4, R * 0.03), (1.0, 0.94, 0.84), 0.8)
            dot(k, b, max(0.4, R * 0.03), (1.0, 0.94, 0.84), 0.8)
        }
    }

    func group(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        if o.name.contains("Leo") {
            // M65 and M66 side by side, NGC 3628 edge-on with its dust lane to the north
            var m65 = k
            m65.translateBy(x: 0.45 * R, y: 0.25 * R)
            spiral(m65, R * 0.36, angle: 1.675, ratio: 0.3, pass, &rng)
            var m66 = k
            m66.translateBy(x: -0.35 * R, y: 0.3 * R)
            spiral(m66, R * 0.38, angle: 1.69, ratio: 0.45, pass, &rng)
            var n3628 = k
            n3628.translateBy(x: -0.3 * R, y: -0.6 * R)
            edgeOn(n3628, R * 0.55, 2.897, 0.2, pass)
        } else {
            // Stephan's Quintet: four galaxies interacting, and one (NGC 7320) much nearer, by chance in line
            let gals: [(Double, Double, Double, Double, Bool)] = [
                (0.05, 0.5, 0.2, 0.3, false), (-0.02, 0.1, 0.22, 1.2, false), (0.13, 0.04, 0.2, 2.1, false),
                (-0.42, -0.15, 0.26, 0.6, false), (0.45, 0.28, 0.3, 2.6, true),
            ]
            for g in gals {
                let c = CGPoint(x: g.0 * R, y: g.1 * R)
                if pass == 0 {
                    eglow(k, c, g.2 * R, g.2 * R * 0.65, g.3, g.4 ? (0.75, 0.85, 1.0) : SkyInk.warm, 0.55)
                } else {
                    dot(k, c, max(0.35, R * 0.025), g.4 ? (0.85, 0.9, 1.0) : (1.0, 0.95, 0.85), 0.8)
                }
            }
        }
    }

    // Star clusters

    func cluster(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        switch o.variant {
        case 1:   // globular: hundreds of thousands of old stars packed toward the core
            if pass == 0 {
                glow(k, .zero, R, (1.0, 0.9, 0.72), 0.55)
                glow(k, .zero, R * 0.4, (1.0, 0.95, 0.85), 0.55)
            } else {
                var dots = Path()
                let n = o.name.contains("Omega") ? 150 : 90
                for _ in 0..<n {
                    let a = rng.range(0, CV.tau), rr = R * pow(rng.unit(), 1.6) * 1.05
                    let s = rng.range(0.22, 0.45)
                    dots.addEllipse(in: CGRect(x: cos(a) * rr - s, y: sin(a) * rr - s, width: 2 * s, height: 2 * s))
                }
                k.fill(dots, with: .color(dark ? skyColor((1.0, 0.92, 0.8), 0.6) : CoverPalette.rgb(pal.ink, 0.35)))
            }
        case 2:   // the Double Cluster: h Persei to the west, χ Persei to the east
            for (cx, n) in [(0.45, 22), (-0.45, 26)] {
                let c = CGPoint(x: cx * R, y: 0)
                if pass == 0 { glow(k, c, R * 0.45, SkyInk.hotStar, 0.18) } else { scatter(k, c, R * 0.42, n, &rng, red: cx < 0 ? 3 : 1) }
            }
        case 3:   // the Jewel Box: blue-white supergiants around one orange-red one
            if pass == 1 {
                let pts: [(Double, Double, Double)] = [(0, -0.5, 1.0), (-0.32, 0.1, 0.9), (0.3, 0.12, 0.9), (-0.12, -0.15, 0.6),
                                                       (0.12, -0.18, 0.6), (-0.45, 0.45, 0.55), (0.42, 0.48, 0.55), (0, 0.3, 0.5)]
                for (i, q) in pts.enumerated() {
                    let col: RGB01 = i == 3 ? (1.0, 0.6, 0.35) : (0.75, 0.85, 1.0)
                    dot(k, CGPoint(x: q.0 * R, y: q.1 * R), max(0.45, R * 0.07 * q.2), col, 0.95)
                }
            } else {
                glow(k, .zero, R, SkyInk.hotStar, 0.15)
            }
        default:
            if o.name.contains("Coathanger") {
                // Brocchi's Cluster: a chance alignment that looks just like an upside-down coat hanger
                guard pass == 1 else { return }
                let bar: [(Double, Double)] = [(-0.9, -0.1), (-0.55, -0.12), (-0.2, -0.1), (0.15, -0.12), (0.5, -0.1), (0.85, -0.08)]
                let hook: [(Double, Double)] = [(0.1, 0.12), (0.18, 0.32), (0.05, 0.5), (-0.1, 0.42)]
                for q in bar + hook { dot(k, CGPoint(x: q.0 * R, y: q.1 * R), max(0.45, R * 0.05), (0.9, 0.92, 1.0), 0.9) }
            } else if pass == 0 {
                glow(k, .zero, R, SkyInk.hotStar, 0.12)
            } else {
                scatter(k, .zero, R, o.name.contains("M44") ? 26 : 18, &rng, red: 2)
            }
        }
    }

    func scatter(_ k: GraphicsContext, _ c: CGPoint, _ R: Double, _ n: Int, _ rng: inout SeededRandom, red: Int) {
        for i in 0..<n {
            let a = rng.range(0, CV.tau), rr = R * pow(rng.unit(), 0.8)
            let bright = rng.unit()
            let col: RGB01 = i < red ? (1.0, 0.72, 0.45) : (0.82, 0.88, 1.0)
            let p = CGPoint(x: Double(c.x) + cos(a) * rr, y: Double(c.y) + sin(a) * rr)
            dot(k, p, max(0.35, R * (0.02 + 0.03 * bright)), col, 0.55 + 0.4 * bright)
        }
    }

    // Dark nebulae

    func darkNebula(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int, _ rng: inout SeededRandom) {
        guard pass == 0 else { return }
        let shadow = CV.mix(pal.bottom01, (0, 0, 0), dark ? 0.55 : 0.12)
        if o.variant == 1 {
            // The Horsehead: a pillar of dust silhouetted against the glowing red strip IC 434
            eglow(k, CGPoint(x: 0.35 * R, y: 0), R * 0.6, R * 1.25, 0, SkyInk.hAlpha, 0.55)
            var cloudPath = Path()
            cloudPath.move(to: CGPoint(x: -1.4 * R, y: -1.4 * R))
            cloudPath.addLine(to: CGPoint(x: -0.2 * R, y: -1.4 * R))
            cloudPath.addQuadCurve(to: CGPoint(x: -0.12 * R, y: 0.55 * R), control: CGPoint(x: -0.35 * R, y: -0.4 * R))
            cloudPath.addQuadCurve(to: CGPoint(x: 1.4 * R, y: 0.7 * R), control: CGPoint(x: 0.6 * R, y: 0.5 * R))
            cloudPath.addLine(to: CGPoint(x: 1.4 * R, y: 1.4 * R))
            cloudPath.addLine(to: CGPoint(x: -1.4 * R, y: 1.4 * R))
            cloudPath.closeSubpath()
            k.fill(cloudPath, with: .color(skyColor(shadow, 0.8)))
            let head: [(Double, Double)] = [
                (0.12, 0.65), (0.1, 0.3), (0.02, 0.12), (-0.1, 0.05), (-0.17, -0.02), (-0.1, -0.12), (0.05, -0.25),
                (0.12, -0.42), (0.17, -0.48), (0.2, -0.33), (0.3, -0.2), (0.42, 0.15), (0.5, 0.65),
            ]
            let pts = head.map { CGPoint(x: $0.0 * R * 1.3, y: $0.1 * R * 1.3) }
            let shape = CV.curve(pts, closed: true)
            k.fill(shape, with: .color(skyColor(shadow, 0.92)))
            k.stroke(shape, with: .color(neb((1.0, 0.6, 0.6), 0.18)), lineWidth: max(0.4, R * 0.04))
        } else {
            // The Coalsack: a cloud of dust 600 light-years away, blotting out the Milky Way
            var r = k
            r.rotate(by: .radians(o.angle))
            let h = R * max(0.5, o.ratio)
            eglow(r, .zero, R, h, 0, shadow, 0.75, raw: true)
            for _ in 0..<6 {
                let c = CGPoint(x: rng.range(-0.5, 0.5) * R, y: rng.range(-0.5, 0.5) * h)
                eglow(r, c, R * rng.range(0.3, 0.55), h * rng.range(0.3, 0.5), rng.range(0, 3), shadow, 0.45, raw: true)
            }
        }
    }

    /// The ρ Ophiuchi clouds: Antares lights its dust gold, ρ Oph lights blue dust, σ Sco red hydrogen —
    /// each glow placed at its star's real position.
    func complexCloud(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, _ pass: Int) {
        guard pass == 0 else { return }
        func local(_ ra: Double, _ dec: Double) -> CGPoint? {
            guard let p = d.field.project(ra: ra, dec: dec) else { return nil }
            return CGPoint(x: Double(p.x - o.p.x) * w, y: Double(p.y - o.p.y) * w)
        }
        if let a = local(247.3519, -26.4320) { glow(k, a, R * 0.45, (1.0, 0.78, 0.4), 0.45) }
        if let b = local(246.3956, -23.4472) { glow(k, b, R * 0.4, SkyInk.dust, 0.5) }
        if let s = local(245.2971, -25.5928) { glow(k, s, R * 0.35, SkyInk.hAlpha, 0.45) }
        var r = k
        r.rotate(by: .radians(o.angle))
        for i in 0..<3 {
            let y0 = (Double(i) - 1) * 0.18 * R
            lane(r, [CGPoint(x: -0.2 * R, y: y0), CGPoint(x: 0.4 * R, y: y0 + 0.08 * R),
                     CGPoint(x: 1.0 * R, y: y0 - 0.05 * R), CGPoint(x: 1.5 * R, y: y0 + 0.1 * R)], R * 0.09, 0.55)
        }
    }

    // MARK: Deep-sky objects — what moves

    func deepSkyLive(_ ctx: GraphicsContext, t: Double) {
        guard !d.field.dsos.isEmpty else { return }
        var c = ctx
        c.blendMode = dark ? .screen : .normal
        for (i, o) in d.field.dsos.enumerated() {
            let R = radius(o)
            var k = c
            let p = pt(o.p)
            k.translateBy(x: p.x, y: p.y)
            let phase = Double(i) * 1.7
            let breathe = 0.5 + 0.5 * sin(CV.tau * t / 11 + phase)
            switch o.kind {
            case SKY_EMISSION, SKY_TRIFID, SKY_ROSETTE, SKY_COMPLEX:
                glow(k, .zero, R * 0.75, SkyInk.hAlpha, 0.04 + 0.05 * breathe)
            case SKY_PILLARS:
                // the pillar tips glow where the cluster's ultraviolet light is boiling them away
                for col in CoverPainter.pillarTable {
                    glow(k, pillarTip(col, R), R * 0.18, (1.0, 0.85, 0.6), 0.1 + 0.1 * breathe)
                }
            case SKY_PN_RING, SKY_PN_BIPOLAR:
                // the shell keeps expanding at about 20 km/s; a faint halo drifts outward
                let u = (t / 24 + phase).truncatingRemainder(dividingBy: 1)
                k.stroke(CV.circle(.zero, R * (0.9 + 0.5 * u)), with: .color(neb(SkyInk.oxygen, 0.1 * (1 - u))), lineWidth: max(0.4, R * 0.05))
                let tw = 0.75 + 0.25 * sin(CV.tau * t / 3.1 + phase)
                glow(k, .zero, R * 0.16, (0.9, 0.95, 1.0), 0.35 * tw, raw: dark)
            case SKY_SNR:
                if o.variant == 0 {
                    // the Crab Pulsar flashes 30 times a second; shown 100 times slower
                    pulsar(k, R, period: max(0.001, o.period) * 100, t: t, beams: false)
                } else {
                    let u = (t / 30 + phase).truncatingRemainder(dividingBy: 1)
                    k.stroke(CV.circle(.zero, R * (0.7 + 0.4 * u)), with: .color(neb(SkyInk.oxygen, 0.08 * sin(Double.pi * u))),
                             lineWidth: max(0.5, R * 0.06))
                }
            case SKY_GALAXY:
                glow(k, .zero, R * 0.3, SkyInk.warm, 0.06 + 0.07 * breathe)
                if o.variant == 3 { jetKnots(k, o, R, t: t) }
            case SKY_BLACKHOLE:
                if o.variant == 0 { photonRing(k, R, t: t) } else { cygnusX1(k, R, t: t) }
            case SKY_PULSAR:
                // PSR B1919+21 pulses at its true period; the Vela pulsar (11 a second) is slowed 20 times
                let period = o.variant == 0 ? o.period : o.period * 20
                pulsar(k, R, period: max(0.05, period), t: t, beams: true)
            case SKY_ECHO:
                lightEcho(k, R, t: t)
            default:
                break
            }
        }
    }

    func pulsar(_ k: GraphicsContext, _ R: Double, period: Double, t: Double, beams: Bool) {
        let ph = (t / period).truncatingRemainder(dividingBy: 1)
        let d0 = (ph - 0.5) / 0.12
        let pulse = exp(-d0 * d0)
        let col: RGB01 = (0.75, 0.85, 1.0)
        glow(k, .zero, R * (0.25 + 0.35 * pulse), col, 0.22 + 0.55 * pulse, raw: dark)
        k.fill(CV.circle(.zero, max(0.5, R * 0.05)), with: .color(ink((0.95, 0.97, 1.0), 0.9)))
        guard beams else { return }
        var r = k
        r.rotate(by: .radians(ph * CV.tau))
        for s in [-1.0, 1.0] {
            var cone = Path()
            cone.move(to: .zero)
            cone.addLine(to: CGPoint(x: s * R * 1.1, y: -R * 0.16))
            cone.addLine(to: CGPoint(x: s * R * 1.1, y: R * 0.16))
            cone.closeSubpath()
            r.fill(cone, with: .linearGradient(Gradient(colors: [ink(col, 0.18), ink(col, 0)]),
                                               startPoint: .zero, endPoint: CGPoint(x: s * R * 1.1, y: 0)))
        }
    }

    /// Sagittarius A*, as the Event Horizon Telescope imaged it: a ring of hot gas around the black hole's
    /// shadow, brighter where the gas moves toward us. Hot spots circle it (here once every 40 seconds).
    func photonRing(_ k: GraphicsContext, _ R: Double, t: Double) {
        let ringPath = CV.circle(.zero, R * 0.62)
        k.stroke(ringPath, with: .color(skyColor((1.0, 0.55, 0.22), 0.42)), lineWidth: max(0.8, R * 0.26))
        let spin = Angle.radians(t * CV.tau / 40)
        let g = Gradient(colors: [skyColor((1.0, 0.88, 0.6), 0.85), skyColor((1.0, 0.55, 0.2), 0.08),
                                  skyColor((1.0, 0.7, 0.4), 0.3), skyColor((1.0, 0.88, 0.6), 0.85)])
        k.stroke(ringPath, with: .conicGradient(g, center: .zero, angle: spin), lineWidth: max(0.6, R * 0.16))
    }

    /// Cygnus X-1: a blue supergiant and a black hole of 21 Suns orbiting every 5.6 days (here 40 seconds);
    /// gas torn from the star spirals into a hot accretion disc.
    func cygnusX1(_ k: GraphicsContext, _ R: Double, t: Double) {
        let a = t * CV.tau / 40
        let star = CGPoint(x: cos(a) * R * 0.45, y: sin(a) * R * 0.18)
        let hole = CGPoint(x: -cos(a) * R * 0.3, y: -sin(a) * R * 0.12)
        var e = k
        e.translateBy(x: hole.x, y: hole.y)
        e.scaleBy(x: 1, y: 0.35)
        e.fill(CV.circle(.zero, R * 0.32), with: .radialGradient(Gradient(colors: [skyColor((1.0, 0.95, 0.85), 0.75),
                                                                                   skyColor((1.0, 0.6, 0.3), 0.45),
                                                                                   skyColor((1.0, 0.4, 0.2), 0)]),
                                                                 center: .zero, startRadius: 0, endRadius: R * 0.32))
        var stream = Path()
        stream.move(to: star)
        let mid = CV.mid(star, hole)
        stream.addQuadCurve(to: hole, control: CGPoint(x: Double(mid.x), y: Double(mid.y) - R * 0.15))
        k.stroke(stream, with: .color(skyColor((0.75, 0.82, 1.0), 0.3)), lineWidth: max(0.4, R * 0.04))
        glow(k, star, R * 0.32, (0.7, 0.8, 1.0), 0.6, raw: dark)
        k.fill(CV.circle(star, max(0.6, R * 0.09)), with: .color(ink((0.85, 0.9, 1.0), 0.95)))
    }

    /// M87's jet: knots of plasma that appear to move faster than light (an illusion of their near-light speed).
    func jetKnots(_ k: GraphicsContext, _ o: SkyDSO, _ R: Double, t: Double) {
        var r = k
        r.rotate(by: .radians(o.angle))
        for i in 0..<4 {
            let u = (t / 16 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
            glow(r, CGPoint(x: u * R * 0.95, y: 0), R * 0.07, (0.75, 0.85, 1.0), 0.45 * (1 - u), raw: dark)
        }
    }

    /// V838 Monocerotis, 2002: the flash of its outburst swept outward through the surrounding dust.
    func lightEcho(_ k: GraphicsContext, _ R: Double, t: Double) {
        for i in 0..<3 {
            let u = (t / 36 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let rr = R * (0.15 + 0.9 * u)
            let a = sin(Double.pi * u)
            k.stroke(CV.circle(.zero, rr), with: .color(neb((0.95, 0.65, 0.45), 0.22 * a)), lineWidth: max(0.5, R * 0.12 * (1 - u * 0.5)))
            k.stroke(CV.circle(.zero, rr * 0.92), with: .color(neb((0.6, 0.75, 1.0), 0.12 * a)), lineWidth: max(0.4, R * 0.05))
        }
        k.fill(CV.circle(.zero, max(0.5, R * 0.05)), with: .color(ink((1.0, 0.45, 0.35), 0.9)))
    }

    // MARK: Mist

    func orbs(_ ctx: GraphicsContext, t: Double) {
        var c = ctx
        c.blendMode = dark ? .screen : .normal
        let k = dark ? 0.3 : 0.85
        for o in d.orbs {
            let x = o.x + o.driftX * sin(CV.tau * t / o.periodX + o.phaseX)
            let y = o.y + o.driftY * sin(CV.tau * t / o.periodY + o.phaseY)
            let r = o.r * (1 + o.breath * sin(CV.tau * t / o.breathPeriod + o.breathPhase)) * w
            let q = pt(x, y)
            c.fill(CV.circle(q, r), with: .radialGradient(Gradient(colors: [CoverPalette.rgb(o.color, o.opacity * k), CoverPalette.rgb(o.color, 0)]),
                                                          center: q, startRadius: 0, endRadius: r))
        }
    }

    // MARK: Eclipses — sky

    func solarGeometry(_ e: CoverEvents.Eclipse) -> SolarGeometry {
        let moonR = e.kind == 1 ? 0.93 : 1.035
        let s = 1 - 2 * e.u
        // the Moon slides west to east across the Sun (right to left here), lingering near mid-eclipse
        let x = 2.15 * (s < 0 ? -1.0 : 1.0) * pow(abs(s), 2.2)
        let y = e.kind == 4 ? 0.55 : 0
        let sep = (x * x + y * y).squareRoot()
        let c2 = moonR - 1
        let totality = e.kind == 0 ? CV.smooth((c2 + 0.02 - sep) / 0.02) : 0
        let coverage = CV.clamp((1 + moonR - sep) / 2)
        let fade = CV.smooth(min(e.u, 1 - e.u) / 0.07)
        return SolarGeometry(x: x, y: y, moonR: moonR, sep: sep, totality: totality, coverage: coverage, fade: fade)
    }

    func lunarGeometry(_ e: CoverEvents.Eclipse) -> LunarGeometry {
        // Earth's shadow at the Moon: umbra about 2.7 lunar radii across, penumbra about 4.7
        let s = 1 - 2 * e.u
        let x = -7.2 * (s < 0 ? -1.0 : 1.0) * pow(abs(s), 1.7)
        let y = e.kind == 2 ? 0.35 : (e.kind == 3 ? 2.2 : 3.9)
        let sep = (x * x + y * y).squareRoot()
        let umbra = CV.clamp((3.7 - sep) / 2)
        let fade = CV.smooth(min(e.u, 1 - e.u) / 0.08)
        return LunarGeometry(x: x, y: y, umbra: umbra, fade: fade)
    }

    /// How dark the sky has become: totality turns day to deep twilight.
    func nightFactor(_ ev: CoverEvents) -> Double {
        guard let e = ev.eclipse else { return 0 }
        switch e.kind {
        case 0:
            let g = solarGeometry(e)
            return g.fade * (0.35 * CV.smooth((g.coverage - 0.7) / 0.3) + 0.65 * g.totality)
        case 1, 4:
            let g = solarGeometry(e)
            return g.fade * 0.25 * CV.smooth((g.coverage - 0.65) / 0.35)
        default:
            let g = lunarGeometry(e)
            return dark ? g.fade * 0.3 * g.umbra : 0
        }
    }

    func eclipseSky(_ ctx: GraphicsContext, night: Double, solar: Bool) {
        guard night > 0.005 else { return }
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .color(skyColor((0.03, 0.04, 0.09), (dark ? 0.35 : 0.72) * night)))
        if solar {
            // a sunset all round the horizon: beyond the Moon's shadow the air is still sunlit
            let y0 = Double(size.height) * 0.6
            ctx.fill(Path(CGRect(x: 0, y: y0, width: Double(size.width), height: Double(size.height) - y0)),
                     with: .linearGradient(Gradient(colors: [skyColor((1.0, 0.55, 0.3), 0), skyColor((1.0, 0.55, 0.3), 0.35 * night)]),
                                           startPoint: CGPoint(x: 0, y: y0), endPoint: CGPoint(x: 0, y: size.height)))
        }
    }

    // MARK: Aurora

    /// Aurora on the polar constellations, as strong as the live planetary K-index:
    /// green oxygen (557.7 nm) low down, red oxygen (630 nm) high up in strong storms,
    /// and a violet nitrogen fringe (427.8 nm) along the lower edge when it is very active.
    func aurora(_ ctx: GraphicsContext, t: Double, kp: Double) {
        guard d.field.aurora != 0, dark else { return }
        let a = CV.clamp((kp - 0.5) / 6.5, 0.18, 1)
        var c = ctx
        c.blendMode = .screen
        let n = 34
        let x0 = -0.05, x1 = 1.05
        let strip = (x1 - x0) / Double(n)
        for i in 0..<n {
            let x = x0 + (Double(i) + 0.5) * strip
            let base = 1.14 + 0.07 * sin(CV.tau * (x * 0.9 + t / 41)) + 0.035 * sin(CV.tau * (x * 2.3 - t / 23))
            let height = (0.22 + 0.4 * a) * (0.65 + 0.35 * sin(CV.tau * (x * 1.7 + t / 31) + 1.3))
            let ray = 0.55 + 0.45 * sin(CV.tau * (x * 7.3 + t / 9) + Double(i) * 0.7)
            let top = base - height
            let rect = CGRect(x: (x - strip * 0.75) * w, y: top * w, width: strip * 1.5 * w, height: (height + 0.03) * w)
            let g = Gradient(stops: [
                .init(color: skyColor(SkyInk.auroraRed, 0), location: 0),
                .init(color: skyColor(SkyInk.auroraRed, 0.22 * a * a * ray), location: 0.18),
                .init(color: skyColor(SkyInk.auroraGreen, 0.12 * a * ray), location: 0.45),
                .init(color: skyColor(SkyInk.auroraGreen, 0.42 * a * ray), location: 0.9),
                .init(color: skyColor(SkyInk.auroraViolet, 0.25 * max(0, a - 0.55) * ray), location: 0.96),
                .init(color: skyColor(SkyInk.auroraViolet, 0), location: 1),
            ])
            c.fill(Path(rect), with: .linearGradient(g, startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
        }
    }

    // MARK: Stars

    /// Parallax: the whole sky sways gently, and each star moves in proportion to its nearness.
    func drift(_ parallax: Double, _ t: Double) -> (Double, Double) {
        let A = 0.014
        let dx = A * parallax * sin(CV.tau * t / d.driftTx + d.driftPx)
        let dy = 0.7 * A * parallax * sin(CV.tau * t / d.driftTy + d.driftPy)
        return (dx, dy)
    }

    func starPoint(_ s: SkyStar, _ t: Double) -> CGPoint {
        let (dx, dy) = drift(s.parallax, t)
        return CGPoint(x: Double(s.p.x) + dx, y: Double(s.p.y) + dy)
    }

    /// Variable stars follow the shapes of their real light curves, sped up.
    func liveMag(_ s: SkyStar, _ t: Double, _ ev: CoverEvents) -> Double {
        switch s.variable {
        case 1:   // Algol: eclipsed by its companion every 2.87 days (here every minute)
            let ph = (t / 60 + 0.37).truncatingRemainder(dividingBy: 1)
            let sigma = 0.028
            let d1 = (ph - 0.5) / sigma
            let d2 = min(ph, 1 - ph) / sigma
            return 2.09 + 1.3 * exp(-0.5 * d1 * d1) + 0.06 * exp(-0.5 * d2 * d2)
        case 2:   // Mira: from 2nd to 10th magnitude and back every 332 days (here two minutes)
            let ph = (t / 120 + 0.2).truncatingRemainder(dividingBy: 1)
            return 6.0 - 3.6 * cos(CV.tau * ph + 0.35 * sin(CV.tau * ph))
        case 3:   // δ Cephei: quick rise, slow fade every 5.37 days (here 45 seconds)
            let ph = (t / 45).truncatingRemainder(dividingBy: 1)
            let shape = ph < 0.25 ? ph / 0.25 : 1 - (ph - 0.25) / 0.75
            return 4.37 - 0.9 * shape
        case 4:   // Betelgeuse: its slow pulsations, and the Great Dimming of 2019–20 replayed now and then
            return s.mag + 1.15 * ev.dimming + 0.12 * sin(CV.tau * t / 90)
        default:
            return s.mag
        }
    }

    func starRadius(_ mag: Double) -> Double {
        let b = pow(10, -0.4 * (mag - 6.5))
        return max(0.35, w * 0.0028 * pow(b, 0.22))
    }

    /// Point-mass gravitational lens: a source at angular offset β (u = β/θE in Einstein radii) appears as two
    /// images at θ± = θE (u ± √(u²+4)) / 2, stretched along the ring by θ/β and across it by dθ/dβ.
    func lensImages(_ p: CGPoint, _ L: Lens) -> [(p: CGPoint, tangential: Double, radial: Double, angle: Double)]? {
        let dx = Double(p.x - L.center.x), dy = Double(p.y - L.center.y)
        let beta = (dx * dx + dy * dy).squareRoot()
        guard beta < L.theta * 3.5 else { return nil }
        let u = max(0.03, beta / L.theta)
        let root = (u * u + 4).squareRoot()
        let ux = beta > 1e-9 ? dx / beta : 1
        let uy = beta > 1e-9 ? dy / beta : 0
        var out: [(p: CGPoint, tangential: Double, radial: Double, angle: Double)] = []
        for sign in [1.0, -1.0] {
            let th = L.theta * (u + sign * root) / 2
            let tangential = abs(th) / max(1e-6, beta)
            let radial = 0.5 * (1 + sign * u / root)
            let q = CGPoint(x: Double(L.center.x) + ux * th, y: Double(L.center.y) + uy * th)
            out.append((q, min(8, max(0.2, tangential)), min(2.5, max(0.15, radial)), atan2(uy, ux)))
        }
        return out
    }

    func stars(_ ctx: GraphicsContext, t: Double, ev: CoverEvents, night: Double, lens: Lens?) {
        var c = ctx
        c.blendMode = dark ? .screen : .normal
        var faint = [Path(), Path(), Path()]      // night: batched by brightness
        var inked = [Path(), Path(), Path()]      // twilight: batched by brightness
        let lo = -0.05, hiX = 1.05, hiY = units + 0.05
        let (ux, uy) = drift(1, t)                // parallax is linear in nearness: one sway for the whole sky
        for s in d.field.stars {
            let p = CGPoint(x: Double(s.p.x) + ux * s.parallax, y: Double(s.p.y) + uy * s.parallax)
            if Double(p.x) < lo || Double(p.x) > hiX || Double(p.y) < lo || Double(p.y) > hiY { continue }
            let mag = s.variable > 0 ? liveMag(s, t, ev) : s.mag
            if mag > 6.9 { continue }
            var twinkle = 1.0
            if mag < 4.3 && t > 0 { twinkle = 0.86 + 0.14 * sin(CV.tau * t / s.twinklePeriod + s.twinklePhase) }
            if let L = lens, let images = lensImages(p, L) {
                if L.strength < 0.99 { star(c, &faint, &inked, p, mag, s.rgb, twinkle * (1 - L.strength), night, 1, 1, 0) }
                for im in images { star(c, &faint, &inked, im.p, mag, s.rgb, twinkle * L.strength, night, im.tangential, im.radial, im.angle) }
            } else {
                star(c, &faint, &inked, p, mag, s.rgb, twinkle, night, 1, 1, 0)
            }
        }
        if !dark && night < 0.98 {
            let a = 1 - night
            let ink = CV.mix(pal.ink01, (0.5, 0.55, 0.7), 0.15)
            let alphas = [0.66, 0.52, 0.34]
            for i in 0..<3 { c.fill(inked[i], with: .color(skyColor(ink, alphas[i] * a))) }
        }
        if dark || night > 0.02 {
            let a = dark ? 1.0 : night
            let alphas = [0.8, 0.6, 0.42]
            for i in 0..<3 { c.fill(faint[i], with: .color(skyColor((0.92, 0.94, 1.0), alphas[i] * a))) }
        }
    }

    /// One star, or one lensed image of it. Bright stars get a coloured glow; faint ones are batched.
    func star(_ c: GraphicsContext, _ faint: inout [Path], _ inked: inout [Path], _ p: CGPoint, _ mag: Double, _ rgb: RGB01,
              _ alpha: Double, _ night: Double, _ st: Double, _ sr: Double, _ angle: Double) {
        let r = starRadius(mag)
        let q = pt(p)
        let stretched = abs(st - 1) > 0.05 || abs(sr - 1) > 0.05
        func shape(_ radius: Double) -> Path {
            if !stretched { return CV.circle(q, radius) }
            let tr = CGAffineTransform(translationX: q.x, y: q.y).rotated(by: angle)
            return Path(ellipseIn: CGRect(x: -radius * sr, y: -radius * st, width: 2 * radius * sr, height: 2 * radius * st)).applying(tr)
        }
        if !dark {
            // twilight: the real star pattern as soft points of ink, the brightest strongest
            if mag < 4.9 && night < 0.98 {
                if stretched || alpha < 0.8 {     // lensed or fading: draw it alone; otherwise batch it
                    let a = (mag < 2 ? 0.66 : (mag < 3.4 ? 0.52 : 0.34)) * alpha * (1 - night)
                    c.fill(shape(r * 1.1), with: .color(skyColor(CV.mix(pal.ink01, rgb, 0.18), a)))
                } else {
                    let rr = r * 1.1
                    inked[mag < 2 ? 0 : (mag < 3.4 ? 1 : 2)].addEllipse(in: CGRect(x: Double(q.x) - rr, y: Double(q.y) - rr, width: 2 * rr, height: 2 * rr))
                }
                if mag < 2.2 { c.fill(shape(r * 3.2), with: .color(skyColor(CV.mix(pal.ink01, rgb, 0.3), 0.09 * alpha * (1 - night)))) }
            }
            if night <= 0.02 { return }
        }
        let a = dark ? alpha : alpha * night
        if mag >= 4.3 {
            let bucket = mag < 5.0 ? 0 : (mag < 5.7 ? 1 : 2)
            if stretched {
                faint[bucket].addPath(shape(r))
            } else {
                faint[bucket].addEllipse(in: CGRect(x: Double(q.x) - r, y: Double(q.y) - r, width: 2 * r, height: 2 * r))
            }
            return
        }
        let core = CV.mix(rgb, (1, 1, 1), 0.55)
        if stretched {
            c.fill(shape(r * 2.2), with: .color(skyColor(rgb, 0.18 * a)))
            c.fill(shape(r), with: .color(skyColor(core, a)))
            return
        }
        let reach = r * (mag < 1.5 ? 6.0 : (mag < 3 ? 4.2 : 3.2))
        glow(c, q, reach, rgb, (mag < 1.5 ? 0.32 : 0.22) * a, raw: true)
        c.fill(CV.circle(q, r), with: .color(skyColor(core, a)))
        if mag < 0.6 { spikes(c, q, r * 7, skyColor(rgb, 0.2 * a), max(0.4, r * 0.25)) }
    }

    /// Star trails around the celestial pole, as in a long-exposure photograph: the arcs grow as the
    /// "exposure" lengthens, then fade and start again. The sky turns once every 23 h 56 min.
    func trails(_ ctx: GraphicsContext, t: Double) {
        let f = d.field
        guard f.pole >= 0, t > 0, dark else { return }
        var pole = f.project(ra: 0, dec: 90)
        if pole == nil && f.pole < f.stars.count { pole = f.stars[f.pole].p }
        guard let center = pole else { return }
        let u = (t / 200 + 0.3).truncatingRemainder(dividingBy: 1)
        let span = 0.7 * CV.smooth(u / 0.75)
        let fade = u < 0.75 ? 1 : 1 - (u - 0.75) / 0.25
        guard span > 0.01 else { return }
        var c = ctx
        c.blendMode = .screen
        for s in f.stars where s.mag < 4.6 {
            let dx = Double(s.p.x - center.x), dy = Double(s.p.y - center.y)
            if (dx * dx + dy * dy).squareRoot() < 0.01 { continue }
            var path = Path()
            let n = 14
            for j in 0...n {
                let a = -span * Double(j) / Double(n)            // earlier positions: turned back the other way
                let x = Double(center.x) + dx * cos(a) + dy * sin(a)
                let y = Double(center.y) - dx * sin(a) + dy * cos(a)
                if j == 0 { path.move(to: pt(x, y)) } else { path.addLine(to: pt(x, y)) }
            }
            let strength = 0.4 * fade * min(1, (5 - s.mag) / 3)
            let end = path.currentPoint ?? pt(s.p)
            c.stroke(path, with: .linearGradient(Gradient(colors: [skyColor(s.rgb, strength), skyColor(s.rgb, 0)]),
                                                 startPoint: pt(s.p), endPoint: end),
                     style: StrokeStyle(lineWidth: max(0.4, starRadius(s.mag) * 0.9), lineCap: .round))
        }
    }

    /// The constellation figure: a faint ghost, drawn in one line per bookmark (seven complete it).
    func figure(_ ctx: GraphicsContext, t: Double, bookmarks: Int) {
        let f = d.field
        guard !f.segs.isEmpty else { return }
        let fraction = min(1, Double(max(0, bookmarks)) / 7)
        let lit = Int((Double(f.segs.count) * fraction).rounded(.up))
        var ghost = Path(), bright = Path()
        let gap = 0.016
        for (i, sg) in f.segs.enumerated() {
            guard sg.0 >= 0, sg.1 >= 0, sg.0 < f.stars.count, sg.1 < f.stars.count else { continue }
            let a = starPoint(f.stars[sg.0], t), b = starPoint(f.stars[sg.1], t)
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > gap * 2.5 else { continue }
            let ux = dx / len, uy = dy / len
            let p0 = pt(Double(a.x) + ux * gap, Double(a.y) + uy * gap)
            let p1 = pt(Double(b.x) - ux * gap, Double(b.y) - uy * gap)
            if i < lit {
                bright.move(to: p0)
                bright.addLine(to: p1)
            } else {
                ghost.move(to: p0)
                ghost.addLine(to: p1)
            }
        }
        let lineColor: RGB01 = dark ? (0.86, 0.9, 1.0) : pal.ink01
        ctx.stroke(ghost, with: .color(skyColor(lineColor, dark ? 0.15 : 0.2)),
                   style: StrokeStyle(lineWidth: max(0.5, w * 0.0035), lineCap: .round))
        guard lit > 0 else { return }
        let shimmer = 0.85 + 0.15 * sin(CV.tau * t / 7)
        let warm: RGB01 = dark ? (1.0, 0.9, 0.7) : pal.ink01
        var g = ctx
        g.blendMode = dark ? .screen : .normal
        g.stroke(bright, with: .color(skyColor(warm, 0.16 * shimmer)), style: StrokeStyle(lineWidth: max(1.5, w * 0.012), lineCap: .round))
        g.stroke(bright, with: .color(skyColor(warm, 0.5 * shimmer)), style: StrokeStyle(lineWidth: max(0.6, w * 0.004), lineCap: .round))
    }

    /// Tonight's planets, wherever they really are. Planets shine steadily — they don't twinkle.
    @discardableResult
    func planets(_ ctx: GraphicsContext, t: Double, sky: SkyNow, night: Double) -> [(SkyPlanet, CGPoint)] {
        var placed: [(SkyPlanet, CGPoint)] = []
        var c = ctx
        c.blendMode = dark ? .screen : .normal
        let (dx, dy) = drift(1, t)
        for pl in sky.planets where pl.visible {
            guard let p0 = d.field.project(ra: pl.ra, dec: pl.dec) else { continue }
            let p = CGPoint(x: Double(p0.x) + dx, y: Double(p0.y) + dy)
            guard p.x > 0.02, p.x < 0.98, p.y > 0.02, Double(p.y) < units - 0.02 else { continue }
            placed.append((pl, p))
            let q = pt(p)
            let r = max(0.8, starRadius(pl.mag) * 1.1)
            if dark || night > 0.02 {
                let a = dark ? 1.0 : night
                glow(c, q, r * 4.5, pl.rgb, 0.3 * a, raw: true)
                c.fill(CV.circle(q, r), with: .color(skyColor(CV.mix(pl.rgb, (1, 1, 1), 0.35), a)))
            }
            if !dark && night < 0.98 {
                c.fill(CV.circle(q, r * 1.15), with: .color(skyColor(CV.mix(pl.rgb, pal.ink01, 0.6), 0.75 * (1 - night))))
            }
        }
        return placed
    }

    // MARK: Historic supernovae and novae

    func flare(_ ctx: GraphicsContext, t: Double, _ fl: CoverEvents.Flare) {
        guard let fp = d.flarePoint, d.field.flare >= 0, let ptr = sky_flare_at(Int32(d.field.flare)) else { return }
        let f = ptr.pointee
        let u = fl.u
        // light curve: a quick rise to peak, then a long fade (slower for Eta Carinae's eruption)
        let rise = 0.08
        let decay = f.kind == 2 ? 0.45 : 0.28
        var b = u < rise ? CV.smooth(u / rise) : exp(-(u - rise) / decay)
        b *= CV.smooth((1 - u) / 0.1)
        let scale = CV.clamp((8 - Double(f.mag)) / 14, 0.25, 1)
        let (dx, dy) = drift(0.05, t)
        let q = pt(Double(fp.x) + dx, Double(fp.y) + dy)
        // supernovae cool from blue-white to orange; novae fade into the red of hydrogen
        let hot: RGB01 = (0.85, 0.9, 1.0)
        let late: RGB01 = f.kind == 0 ? (1.0, 0.62, 0.4) : (1.0, 0.45, 0.45)
        let col = CV.mix(hot, late, CV.clamp((u - rise) / 0.5))
        var c = ctx
        c.blendMode = dark ? .screen : .normal
        let r = w * (0.006 + 0.014 * scale)
        glow(c, q, r * 7 * b, col, 0.4 * b, raw: dark)
        c.fill(CV.circle(q, max(0.5, r * b)), with: .color(ink(CV.mix(col, (1, 1, 1), 0.6), b)))
        if dark { spikes(c, q, r * 9 * b, skyColor(col, 0.35 * b), max(0.4, r * 0.18)) }
        if f.kind == 3 {
            for i in 0..<2 {
                let rr = r * (3 + 10 * u + Double(i) * 3)
                c.stroke(CV.circle(q, rr), with: .color(ink((0.95, 0.7, 0.5), 0.18 * (1 - u))), lineWidth: max(0.5, r * 0.8))
            }
        }
    }

    // MARK: Comets

    func cometPath(_ e: CoverEvents.Comet) -> (CGPoint, CGPoint) {
        let h1 = CV.hash(e.seed, 1), h2 = CV.hash(e.seed, 2), h3 = CV.hash(e.seed, 3)
        let leftToRight = h3 < 0.5
        let y0 = 0.16 + 0.32 * h1
        let p0 = CGPoint(x: leftToRight ? 0.18 : 0.82, y: y0)
        let p1 = CGPoint(x: 0.5, y: y0 + (h2 - 0.5) * 0.16)
        return (p0, p1)
    }

    func cometHead(_ e: CoverEvents.Comet) -> CGPoint {
        let (p0, p1) = cometPath(e)
        return CGPoint(x: Double(p0.x) + Double(p1.x - p0.x) * e.u, y: Double(p0.y) + Double(p1.y - p0.y) * e.u)
    }

    /// A great comet: a straight blue ion tail streaming directly away from the Sun, a broad curved
    /// dust tail lagging behind its motion, and the comet's own quirks (anti-tail, striae, horns).
    func comet(_ ctx: GraphicsContext, _ e: CoverEvents.Comet) {
        guard let ptr = sky_comet_at(Int32(e.index)) else { return }
        let cm = ptr.pointee
        let (p0, p1) = cometPath(e)
        let head = cometHead(e)
        let env = pow(sin(Double.pi * e.u), 0.7)
        guard env > 0.01 else { return }
        // the Sun is below the horizon; tails point away from it
        let sun = CGPoint(x: 0.5, y: 2.6)
        var ax = Double(head.x - sun.x), ay = Double(head.y - sun.y)
        let al = max(1e-6, (ax * ax + ay * ay).squareRoot())
        ax /= al
        ay /= al
        var mx = Double(p1.x - p0.x), my = Double(p1.y - p0.y)
        let ml = max(1e-6, (mx * mx + my * my).squareRoot())
        mx /= ml
        my /= ml
        // the side the dust lags toward: against the motion, across the anti-sun axis
        let along = -mx * ax - my * ay
        var lx = -mx - along * ax, ly = -my - along * ay
        let ll = (lx * lx + ly * ly).squareRoot()
        if ll < 1e-6 { lx = -ay; ly = ax } else { lx /= ll; ly /= ll }

        var c = ctx
        c.blendMode = dark ? .screen : .normal
        let dust = Double(cm.dust), ion = Double(cm.ion), curve = Double(cm.curve)
        let hx = Double(head.x), hy = Double(head.y)

        // Dust tail
        let Ld = 0.18 + 0.42 * dust
        func center(_ s: Double) -> (Double, Double) {
            (hx + ax * Ld * s + lx * curve * Ld * s * s * 0.7, hy + ay * Ld * s + ly * curve * Ld * s * s * 0.7)
        }
        func tail(_ widthScale: Double) -> Path {
            var left: [CGPoint] = [], right: [CGPoint] = []
            let n = 16
            for j in 0...n {
                let s = Double(j) / Double(n)
                let (cx, cy) = center(s)
                let tx = ax + lx * curve * 1.4 * s, ty = ay + ly * curve * 1.4 * s
                let tl = max(1e-6, (tx * tx + ty * ty).squareRoot())
                let nx = -ty / tl, ny = tx / tl
                let half = (0.006 + 0.07 * dust * s) * (1 + 0.3 * s) * widthScale
                left.append(pt(cx + nx * half, cy + ny * half))
                right.append(pt(cx - nx * half, cy - ny * half))
            }
            var p = Path()
            p.move(to: left[0])
            for q in left.dropFirst() { p.addLine(to: q) }
            for q in right.reversed() { p.addLine(to: q) }
            p.closeSubpath()
            return p
        }
        let (ex, ey) = center(1)
        let dustCol: RGB01 = (1.0, 0.95, 0.84)
        for (scale, alpha) in [(1.0, 0.28), (0.45, 0.4)] {
            c.fill(tail(scale), with: .linearGradient(Gradient(colors: [ink(dustCol, alpha * env * dust), ink(dustCol, 0)]),
                                                      startPoint: pt(head), endPoint: pt(ex, ey)))
        }
        if cm.striae != 0 {
            // striae: dust released in bursts, fanned out by sunlight pressure
            for i in 0..<7 {
                let s0 = 0.22 + 0.06 * Double(i)
                let (sx, sy) = center(s0)
                let fan = (Double(i) - 3) * 0.05
                let dxs = ax + lx * (curve + fan), dys = ay + ly * (curve + fan)
                var p = Path()
                p.move(to: pt(sx, sy))
                p.addLine(to: pt(sx + dxs * Ld * 0.7, sy + dys * Ld * 0.7))
                c.stroke(p, with: .linearGradient(Gradient(colors: [ink(dustCol, 0.22 * env), ink(dustCol, 0)]),
                                                  startPoint: pt(sx, sy), endPoint: pt(sx + dxs * Ld * 0.7, sy + dys * Ld * 0.7)),
                         style: StrokeStyle(lineWidth: max(0.4, w * 0.003), lineCap: .round))
            }
        }

        // Ion tail: gas ionised by sunlight, blown straight back by the solar wind (blue: CO⁺ ions)
        let Li = 0.15 + 0.5 * ion
        let ionCol: RGB01 = (0.5, 0.7, 1.0)
        for (i, off) in [0.0, 0.035, -0.03].enumerated() {
            let ca = cos(off), sa = sin(off)
            let dx = ax * ca - ay * sa, dy = ax * sa + ay * ca
            let len = Li * (1 - 0.2 * Double(i))
            let end = pt(hx + dx * len, hy + dy * len)
            var p = Path()
            p.move(to: pt(head))
            p.addLine(to: end)
            let a0 = (i == 0 ? 0.55 : 0.25) * ion * env
            c.stroke(p, with: .linearGradient(Gradient(colors: [ink(ionCol, a0), ink(ionCol, 0)]), startPoint: pt(head), endPoint: end),
                     style: StrokeStyle(lineWidth: max(0.5, w * (i == 0 ? 0.006 : 0.003)), lineCap: .round))
        }

        // Anti-tail: dust left in the orbital plane, seen edge-on, appearing to point toward the Sun
        if cm.anti != 0 {
            let end = pt(hx - ax * 0.08, hy - ay * 0.08)
            var p = Path()
            p.move(to: pt(head))
            p.addLine(to: end)
            c.stroke(p, with: .linearGradient(Gradient(colors: [ink(dustCol, 0.4 * env), ink(dustCol, 0)]), startPoint: pt(head), endPoint: end),
                     style: StrokeStyle(lineWidth: max(0.5, w * 0.003), lineCap: .round))
        }

        // Coma: green where diatomic carbon fluoresces
        let comaCol: RGB01 = cm.green != 0 ? (0.6, 1.0, 0.7) : (0.85, 0.95, 1.0)
        glow(c, pt(head), w * 0.035, comaCol, 0.75 * env, raw: dark)
        if cm.horns != 0 {
            // the "horns" of 12P/Pons–Brooks: a shell of gas thrown off in an outburst, shadowed by a fragment
            for s in [-1.0, 1.0] {
                var p = Path()
                let base = pt(hx - ax * 0.01 + lx * s * 0.006, hy - ay * 0.01 + ly * s * 0.006)
                let tip = pt(hx - ax * 0.03 + lx * s * 0.03, hy - ay * 0.03 + ly * s * 0.03)
                p.move(to: base)
                p.addQuadCurve(to: tip, control: pt(hx - ax * 0.035 + lx * s * 0.01, hy - ay * 0.035 + ly * s * 0.01))
                c.stroke(p, with: .color(ink(comaCol, 0.45 * env)), style: StrokeStyle(lineWidth: max(0.5, w * 0.004), lineCap: .round))
            }
        }
        c.fill(CV.circle(pt(head), max(0.5, w * 0.004)), with: .color(ink((1, 1, 1), 0.95 * env)))
    }

    // MARK: The Moon

    func moon(_ ctx: GraphicsContext, t: Double, sky: SkyNow, ev: CoverEvents) {
        guard d.hasMoon else { return }
        let (dx, dy) = drift(1, t)
        let center = pt(Double(d.moonCenter.x) + dx, Double(d.moonCenter.y) + dy)
        let R = d.moonD / 2 * w
        if let e = ev.eclipse {
            switch e.kind {
            case 0, 1, 4: solarEclipse(ctx, center, R, e)
            default: lunarEclipse(ctx, center, R, e, t: t)
            }
            return
        }
        moonDisc(ctx, center, R, illum: sky.moonIllum, waxing: sky.waxing, t: t, halo: 1)
    }

    /// The sunlit part: the limb on one side, the terminator (an ellipse) on the other.
    /// Waxing Moons are lit on the right as seen from the northern hemisphere.
    func litPath(_ c: CGPoint, _ R: Double, _ k: Double, _ waxing: Bool) -> Path {
        let s = waxing ? 1.0 : -1.0
        let n = 28
        var p = Path()
        for i in 0...n {
            let a = -Double.pi / 2 + Double.pi * Double(i) / Double(n)
            let q = CGPoint(x: Double(c.x) + s * R * cos(a), y: Double(c.y) + R * sin(a))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        let tx = 1 - 2 * k
        for i in 0...n {
            let a = Double.pi / 2 - Double.pi * Double(i) / Double(n)
            p.addLine(to: CGPoint(x: Double(c.x) + s * tx * R * cos(a), y: Double(c.y) + R * sin(a)))
        }
        p.closeSubpath()
        return p
    }

    /// The near side's maria (x, y, rx, ry in lunar radii; north up, as seen with the naked eye).
    static let mariaTable: [(Double, Double, Double, Double)] = [
        (-0.30, -0.38, 0.30, 0.26),   // Mare Imbrium
        (0.14, -0.38, 0.17, 0.16),    // Mare Serenitatis
        (0.30, -0.08, 0.22, 0.17),    // Mare Tranquillitatis
        (0.66, -0.30, 0.11, 0.10),    // Mare Crisium
        (0.56, 0.18, 0.13, 0.17),     // Mare Fecunditatis
        (0.36, 0.32, 0.09, 0.10),     // Mare Nectaris
        (-0.62, -0.05, 0.26, 0.42),   // Oceanus Procellarum
        (-0.18, 0.38, 0.17, 0.13),    // Mare Nubium
        (-0.50, 0.38, 0.09, 0.09),    // Mare Humorum
        (-0.05, -0.72, 0.38, 0.06),   // Mare Frigoris
        (0.0, -0.17, 0.08, 0.06),     // Mare Vaporum
    ]

    func maria(_ m: GraphicsContext, _ c: CGPoint, _ R: Double, t: Double, alpha: Double, full: Double) {
        // libration: the Moon's slow nodding, which lets us see 59% of its surface (sped up here)
        let lx = 0.035 * sin(CV.tau * t / 61), ly = 0.03 * sin(CV.tau * t / 47 + 1)
        let col: RGB01 = (0.52, 0.55, 0.6)
        let a = (dark ? 0.42 : 0.5) * alpha
        for q in CoverPainter.mariaTable {
            let p = CGPoint(x: Double(c.x) + (q.0 + lx) * R, y: Double(c.y) + (q.1 + ly) * R)
            var e = m
            e.translateBy(x: p.x, y: p.y)
            e.scaleBy(x: 1, y: q.3 / q.2)
            let rr = q.2 * R
            e.fill(CV.circle(.zero, rr), with: .radialGradient(Gradient(stops: [
                .init(color: skyColor(col, a), location: 0),
                .init(color: skyColor(col, a * 0.85), location: 0.55),
                .init(color: skyColor(col, 0), location: 1),
            ]), center: .zero, startRadius: 0, endRadius: rr))
        }
        // bright young craters: Tycho (with its rays near full Moon), Copernicus, Kepler, Aristarchus
        let craters: [(Double, Double, Double)] = [(-0.14, 0.72, 0.55), (-0.30, -0.05, 0.35), (-0.55, -0.07, 0.25), (-0.68, -0.38, 0.5)]
        for (i, q) in craters.enumerated() {
            let p = CGPoint(x: Double(c.x) + (q.0 + lx) * R, y: Double(c.y) + (q.1 + ly) * R)
            m.fill(CV.circle(p, max(0.4, R * (i == 0 ? 0.045 : 0.03))), with: .color(skyColor((1, 1, 0.98), q.2 * alpha)))
        }
        if full > 0.85 {
            let tycho = CGPoint(x: Double(c.x) + (-0.14 + lx) * R, y: Double(c.y) + (0.72 + ly) * R)
            var rays = Path()
            for i in 0..<9 {
                let ang = Double(i) / 9 * CV.tau + 0.3
                let len = R * (0.4 + 0.5 * CV.hash(UInt64(i), 77))
                rays.move(to: tycho)
                rays.addLine(to: CGPoint(x: Double(tycho.x) + cos(ang) * len, y: Double(tycho.y) + sin(ang) * len))
            }
            m.stroke(rays, with: .color(skyColor((1, 1, 0.97), 0.12 * alpha * (full - 0.85) / 0.15)),
                     style: StrokeStyle(lineWidth: max(0.4, R * 0.02), lineCap: .round))
        }
    }

    func moonDisc(_ ctx: GraphicsContext, _ c: CGPoint, _ R: Double, illum k0: Double, waxing: Bool, t: Double, halo: Double) {
        let k = CV.clamp(k0)
        let side = waxing ? 1.0 : -1.0
        let skyHere = skyAt(Double(c.y) / w)
        // moonlight scattered in the air: a halo, stronger the fuller the Moon
        var g = ctx
        g.blendMode = dark ? .screen : .normal
        glow(g, c, R * 2.6, dark ? (0.86, 0.9, 1.0) : (1, 1, 1), (dark ? 0.22 : 0.3) * (0.12 + 0.88 * k) * halo, raw: true)
        if dark {
            // the disc hides the stars behind it…
            ctx.fill(CV.circle(c, R), with: .color(skyColor(CV.mix(skyHere, (0, 0, 0), 0.25), 0.94)))
            // …and earthshine — sunlight bounced off Earth — lights its night side, most of all around new Moon
            let es = 0.06 + 0.16 * pow(1 - k, 2)
            let away = CGPoint(x: Double(c.x) - side * R * 0.3, y: Double(c.y))
            ctx.fill(CV.circle(c, R), with: .radialGradient(Gradient(colors: [skyColor((0.64, 0.7, 0.82), es), skyColor((0.5, 0.56, 0.7), es * 0.5)]),
                                                            center: away, startRadius: 0, endRadius: R * 1.3))
            if k < 0.5 {
                var e = ctx
                e.clip(to: CV.circle(c, R))
                maria(e, c, R, t: t, alpha: 0.16 * (1 - 2 * k), full: 0)
            }
        } else {
            // in twilight the night side is lost in the sky; earthshine barely hints at the disc
            ctx.fill(CV.circle(c, R), with: .color(skyColor(CV.mix(skyHere, (1, 1, 1), 0.5), 0.22 * pow(1 - k, 2))))
        }
        // the sunlit part
        let lit = litPath(c, R, k, waxing)
        let off = side * R * 0.35
        let bright: RGB01 = (0.98, 0.97, 0.93), shade: RGB01 = (0.84, 0.83, 0.8)
        if !dark && k > 0.15 {
            // a soft shadow so a pale Moon still reads against a pale sky (layered strokes, no blur: this runs every frame)
            ctx.stroke(lit, with: .color(skyColor(pal.ink01, 0.05)), style: StrokeStyle(lineWidth: max(2, R * 0.16), lineJoin: .round))
            ctx.stroke(lit, with: .color(skyColor(pal.ink01, 0.07)), style: StrokeStyle(lineWidth: max(1, R * 0.07), lineJoin: .round))
        }
        ctx.fill(lit, with: .radialGradient(Gradient(colors: [skyColor(bright, dark ? 0.98 : 0.96), skyColor(shade, dark ? 0.95 : 0.9)]),
                                            center: CGPoint(x: Double(c.x) + off, y: Double(c.y) - R * 0.1), startRadius: 0, endRadius: R * 1.4))
        if k > 0.04 {   // too thin a sliver to show any maria
            var m = ctx
            m.clip(to: lit)
            maria(m, c, R, t: t, alpha: 1, full: k)
        }
        // A thin crescent is mostly bright limb: let it glow so it reads at any size
        if k < 0.3 {
            let fade = 1 - k / 0.3
            var limb = Path()
            let n = 24
            for i in 0...n {
                let a = -Double.pi * 0.44 + Double.pi * 0.88 * Double(i) / Double(n)
                let q = CGPoint(x: Double(c.x) + side * R * cos(a), y: Double(c.y) + R * sin(a))
                if i == 0 { limb.move(to: q) } else { limb.addLine(to: q) }
            }
            var lg = ctx
            lg.blendMode = dark ? .screen : .normal
            let warm: RGB01 = (1, 0.97, 0.9)
            lg.stroke(limb, with: .color(skyColor(warm, (dark ? 0.12 : 0.2) * fade)),
                      style: StrokeStyle(lineWidth: max(3, R * 0.16), lineCap: .round))
            lg.stroke(limb, with: .color(skyColor(warm, (dark ? 0.28 : 0.4) * fade)),
                      style: StrokeStyle(lineWidth: max(1.4, R * 0.07), lineCap: .round))
            ctx.stroke(limb, with: .color(skyColor((1, 0.99, 0.95), 0.9 * fade)),
                       style: StrokeStyle(lineWidth: max(0.6, R * 0.022), lineCap: .round))
        }
        if dark {
            ctx.stroke(CV.circle(c, R), with: .color(skyColor((1, 1, 1), 0.05)), lineWidth: max(0.5, R * 0.012))
        }
    }

    // MARK: Eclipses — the discs

    func solarEclipse(_ ctx: GraphicsContext, _ c: CGPoint, _ R: Double, _ e: CoverEvents.Eclipse) {
        let sunR = R * 0.9
        let g = solarGeometry(e)
        let moonC = CGPoint(x: Double(c.x) + g.x * sunR, y: Double(c.y) + g.y * sunR)
        let mR = g.moonR * sunR
        let a = g.fade
        guard a > 0.005 else { return }
        var k = ctx
        k.blendMode = dark ? .screen : .normal

        // the corona — the Sun's million-degree outer atmosphere, seen only in totality
        if g.totality > 0.01 { corona(k, c, sunR, e, alpha: a * g.totality) }

        // the bright surface minus the Moon (as through a solar filter: orange)
        let filtered = a * (1 - g.totality)
        if filtered > 0.01 {
            glow(k, c, sunR * 1.9, (1.0, 0.7, 0.35), 0.22 * filtered * (1 - 0.6 * g.coverage), raw: true)
            var layer = ctx
            layer.opacity = 1
            layer.drawLayer { l in
                l.fill(CV.circle(c, sunR), with: .radialGradient(Gradient(colors: [skyColor((1.0, 0.86, 0.55), filtered),
                                                                                   skyColor((1.0, 0.62, 0.25), filtered)]),
                                                                 center: c, startRadius: 0, endRadius: sunR))
                l.blendMode = .destinationOut
                l.fill(CV.circle(moonC, mR), with: .color(.black))
            }
        }
        // the Moon's silhouette
        ctx.fill(CV.circle(moonC, mR), with: .color(skyColor((0.02, 0.02, 0.04), a * (0.55 + 0.45 * g.totality))))
        if e.kind == 0 {
            beads(k, c, sunR, moonC, g, a)
            if g.totality > 0.01 { prominences(k, c, sunR, e, a * g.totality) }
        }
        if e.kind == 1 {
            // the ring of fire
            let ringAlpha = a * CV.smooth((0.12 - g.sep) / 0.08)
            if ringAlpha > 0.01 {
                k.stroke(CV.circle(c, sunR * 0.965), with: .color(skyColor((1.0, 0.8, 0.5), 0.5 * ringAlpha)), lineWidth: max(0.8, sunR * 0.12))
                glow(k, c, sunR * 1.6, (1.0, 0.75, 0.4), 0.25 * ringAlpha, raw: true)
            }
        }
    }

    /// At solar minimum the corona stretches into long equatorial streamers with fine polar plumes;
    /// at maximum it is round and spiky all the way around.
    func corona(_ k: GraphicsContext, _ c: CGPoint, _ sunR: Double, _ e: CoverEvents.Eclipse, alpha: Double) {
        let col: RGB01 = (0.96, 0.97, 1.0)
        glow(k, c, sunR * 2.0, col, 0.5 * alpha, raw: true)
        var rng = SeededRandom(seed: e.seed &* 0x2545_F491_4F6C_DD1D)
        let n = e.corona == 0 ? 6 : (e.corona == 1 ? 9 : 14)
        for i in 0..<n {
            var ang: Double
            var len: Double
            switch e.corona {
            case 0:
                ang = (i % 2 == 0 ? 0 : Double.pi) + rng.range(-0.35, 0.35)
                len = rng.range(2.2, 3.6)
            case 1:
                ang = rng.range(0, CV.tau)
                if abs(sin(ang)) > 0.8 { ang += 0.6 }
                len = rng.range(1.6, 2.8)
            default:
                ang = Double(i) / Double(n) * CV.tau + rng.range(-0.2, 0.2)
                len = rng.range(1.3, 2.4)
            }
            streamer(k, c, sunR, ang, len, rng.range(0.35, 0.7), col, 0.3 * alpha)
        }
        if e.corona == 0 {
            for i in 0..<12 {
                let base = i < 6 ? -Double.pi / 2 : Double.pi / 2
                let ang = base + (Double(i % 6) - 2.5) * 0.14
                var r = k
                r.translateBy(x: c.x, y: c.y)
                r.rotate(by: .radians(ang))
                var p = Path()
                p.move(to: CGPoint(x: sunR, y: 0))
                p.addLine(to: CGPoint(x: sunR * 1.55, y: 0))
                r.stroke(p, with: .linearGradient(Gradient(colors: [skyColor(col, 0.22 * alpha), skyColor(col, 0)]),
                                                  startPoint: CGPoint(x: sunR, y: 0), endPoint: CGPoint(x: sunR * 1.55, y: 0)),
                         lineWidth: max(0.4, sunR * 0.025))
            }
        }
        k.stroke(CV.circle(c, sunR * 1.04), with: .color(skyColor(col, 0.5 * alpha)), lineWidth: max(0.6, sunR * 0.08))
    }

    func streamer(_ k: GraphicsContext, _ c: CGPoint, _ sunR: Double, _ ang: Double, _ len: Double, _ width: Double,
                  _ col: RGB01, _ a: Double) {
        var r = k
        r.translateBy(x: c.x, y: c.y)
        r.rotate(by: .radians(ang))
        let mid = sunR * (0.9 + len) * 0.5
        var p = Path()
        p.move(to: CGPoint(x: sunR * 0.9, y: -sunR * width))
        p.addQuadCurve(to: CGPoint(x: sunR * len, y: 0), control: CGPoint(x: mid, y: -sunR * width * 0.35))
        p.addQuadCurve(to: CGPoint(x: sunR * 0.9, y: sunR * width), control: CGPoint(x: mid, y: sunR * width * 0.35))
        p.closeSubpath()
        r.fill(p, with: .linearGradient(Gradient(colors: [skyColor(col, a), skyColor(col, 0)]),
                                        startPoint: CGPoint(x: sunR * 0.9, y: 0), endPoint: CGPoint(x: sunR * len, y: 0)))
    }

    func prominences(_ k: GraphicsContext, _ c: CGPoint, _ sunR: Double, _ e: CoverEvents.Eclipse, _ a: Double) {
        var rng = SeededRandom(seed: e.seed &+ 99)
        let n = e.corona == 2 ? 5 : 3
        for _ in 0..<n {
            let ang = rng.range(0, CV.tau)
            let h = sunR * rng.range(0.06, 0.16)
            var r = k
            r.translateBy(x: c.x, y: c.y)
            r.rotate(by: .radians(ang))
            var p = Path()
            p.move(to: CGPoint(x: sunR * 1.03, y: -h * 0.6))
            p.addQuadCurve(to: CGPoint(x: sunR * 1.03, y: h * 0.6), control: CGPoint(x: sunR + h * 2.2, y: 0))
            r.stroke(p, with: .color(skyColor(SkyInk.prominence, 0.85 * a)), style: StrokeStyle(lineWidth: max(0.6, h * 0.5), lineCap: .round))
        }
        // the chromosphere: a thin pink rim
        k.stroke(CV.circle(c, sunR * 1.035), with: .color(skyColor(SkyInk.prominence, 0.3 * a)), lineWidth: max(0.5, sunR * 0.03))
    }

    /// Baily's beads and the diamond ring: the last sunlight shining through lunar valleys at the limb.
    func beads(_ k: GraphicsContext, _ c: CGPoint, _ sunR: Double, _ moonC: CGPoint, _ g: SolarGeometry, _ a: Double) {
        let c2 = g.moonR - 1
        let d0 = g.sep - c2
        guard d0 > -0.004, d0 < 0.07 else { return }
        let strength = a * (1 - CV.clamp(abs(d0 - 0.012) / 0.058))
        guard strength > 0.01 else { return }
        let vx = Double(c.x - moonC.x), vy = Double(c.y - moonC.y)
        let base = (vx * vx + vy * vy).squareRoot() < 1e-6 ? Double.pi : atan2(vy, vx)
        let diamond = CGPoint(x: Double(c.x) + cos(base) * sunR, y: Double(c.y) + sin(base) * sunR)
        glow(k, diamond, sunR * 0.9, (1, 1, 0.97), 0.8 * strength, raw: true)
        spikes(k, diamond, sunR * 1.4, skyColor((1, 1, 1), 0.5 * strength), max(0.5, sunR * 0.03))
        for i in -3...3 where i != 0 {
            let ang = base + Double(i) * 0.12
            let bp = CGPoint(x: Double(c.x) + cos(ang) * sunR, y: Double(c.y) + sin(ang) * sunR)
            glow(k, bp, sunR * 0.12, (1, 1, 0.95), 0.9 * strength * (1 - abs(Double(i)) * 0.2), raw: true)
        }
    }

    /// A lunar eclipse: the full Moon passes through Earth's shadow. Inside the umbra it turns copper —
    /// lit only by sunlight bent through every sunrise and sunset on Earth — with a turquoise fringe where
    /// ozone high in the atmosphere filters the light.
    func lunarEclipse(_ ctx: GraphicsContext, _ c: CGPoint, _ R: Double, _ e: CoverEvents.Eclipse, t: Double) {
        let g = lunarGeometry(e)
        moonDisc(ctx, c, R, illum: 1, waxing: true, t: t, halo: 1 - 0.85 * g.umbra * g.fade)
        let sc = CGPoint(x: Double(c.x) + g.x * R, y: Double(c.y) + g.y * R)
        var k = ctx
        k.clip(to: CV.circle(c, R))
        k.fill(CV.circle(sc, R * 4.7), with: .radialGradient(Gradient(stops: [
            .init(color: skyColor((0.1, 0.08, 0.1), 0.45 * g.fade), location: 0.55),
            .init(color: skyColor((0.1, 0.08, 0.1), 0), location: 1),
        ]), center: sc, startRadius: 0, endRadius: R * 4.7))
        k.fill(CV.circle(sc, R * 2.7), with: .radialGradient(Gradient(stops: [
            .init(color: skyColor((0.30, 0.07, 0.04), 0.9 * g.fade), location: 0),
            .init(color: skyColor((0.55, 0.16, 0.07), 0.86 * g.fade), location: 0.8),
            .init(color: skyColor((0.75, 0.32, 0.14), 0.8 * g.fade), location: 0.97),
            .init(color: skyColor((0.75, 0.32, 0.14), 0), location: 1),
        ]), center: sc, startRadius: 0, endRadius: R * 2.7))
        k.stroke(CV.circle(sc, R * 2.62), with: .color(skyColor((0.35, 0.78, 0.86), 0.28 * g.fade)), lineWidth: max(0.6, R * 0.12))
    }

    // MARK: Meteors

    /// Meteors from tonight's active showers, flying straight out of their real radiants, plus sporadic ones.
    /// Fast meteors (Leonids 71 km/s) are short, blue-green and may leave a glowing train; slow ones
    /// (Draconids 20 km/s) are long, lingering and golden.
    func meteors(_ ctx: GraphicsContext, t: Double, sky: SkyNow) {
        guard t > 0 else { return }
        let radiants = ShowerRadiants.shared.points(d.field)
        var sources: [(index: Int, rate: Double)] = [(-1, dark ? 0.75 : 0.35)]
        for (i, z) in sky.showerZHR.enumerated() where z > 0.05 && i < radiants.count && i < SkyShowerInfo.all.count {
            guard let r = radiants[i] else { continue }
            if abs(Double(r.x) - 0.5) > 4 || abs(Double(r.y) - 0.75) > 4 { continue }
            sources.append((i, 4 * min(1, z / 150).squareRoot()))
        }
        let total = sources.reduce(0.0) { $0 + $1.rate }
        let slot = 0.5
        let chance = total * slot / 60
        let k1 = Int(floor(t / slot))
        var c = ctx
        c.blendMode = dark ? .screen : .normal
        for k in (k1 - 9)...k1 {
            let kk = UInt64(bitPattern: Int64(k))
            if CV.hash(d.meteorSeed, kk) >= chance { continue }
            func h(_ n: UInt64) -> Double { CV.hash(d.meteorSeed &+ n &* 0x0100_0000_01B3, kk) }
            var pick = h(9) * total
            var src = sources[0]
            for s in sources {
                if pick < s.rate { src = s; break }
                pick -= s.rate
            }
            let t0 = Double(k) * slot + slot * h(1)
            let age = t - t0
            if age < 0 { continue }
            let speed = src.index >= 0 ? SkyShowerInfo.all[src.index].speed : 15 + 55 * h(2)
            let norm = CV.clamp((speed - 11) / 61)
            let duration = 0.45 + 1.0 * (1 - norm)
            let hasTrain = speed > 55 && h(3) > 0.45
            let trainLife = hasTrain ? 2.8 : 0
            if age > duration + trainLife { continue }
            let start = CGPoint(x: 0.08 + 0.84 * h(4), y: 0.06 + 0.78 * h(5))
            var dx: Double, dy: Double
            var len = 0.1 + 0.22 * h(6)
            if src.index >= 0, let rp = radiants[src.index] {
                dx = Double(start.x - rp.x)
                dy = Double(start.y - rp.y)
                let dl = (dx * dx + dy * dy).squareRoot()
                if dl < 0.02 { continue }
                dx /= dl
                dy /= dl
                len *= min(1, max(0.25, dl / 0.45))             // foreshortened near the radiant
            } else {
                let a = h(7) * CV.tau
                dx = cos(a)
                dy = sin(a)
            }
            let col: RGB01 = speed > 55 ? (0.8, 1.0, 0.86) : (speed < 30 ? (1.0, 0.84, 0.58) : (1.0, 0.97, 0.9))
            let peak = 0.55 + 0.45 * h(8)
            let sx = Double(start.x), sy = Double(start.y)
            if age < duration {
                let u = age / duration
                let headD = len * u, tailD = max(0, headD - len * 0.42)
                let head = pt(sx + dx * headD, sy + dy * headD)
                let tail = pt(sx + dx * tailD, sy + dy * tailD)
                let b = peak * pow(sin(Double.pi * u), 0.6)
                var p = Path()
                p.move(to: tail)
                p.addLine(to: head)
                c.stroke(p, with: .linearGradient(Gradient(colors: [ink(col, 0), ink(col, b)]), startPoint: tail, endPoint: head),
                         style: StrokeStyle(lineWidth: max(0.6, w * 0.0045), lineCap: .round))
                glow(c, head, w * 0.012, col, 0.5 * b, raw: dark)
            }
            if hasTrain {
                // a persistent train: glowing oxygen left by a fast meteor, bent by the upper-air wind
                let tu = (age - duration * 0.5) / (trainLife + duration * 0.5)
                if tu > 0 && tu < 1 {
                    let wind = 0.012 * tu
                    let a0 = pt(sx - dy * wind, sy + dx * wind)
                    let a1 = pt(sx + dx * len - dy * wind * 1.6, sy + dy * len + dx * wind * 1.6)
                    let bend = pt(sx + dx * len * 0.5 - dy * wind * 2.4, sy + dy * len * 0.5 + dx * wind * 2.4)
                    var p = Path()
                    p.move(to: a0)
                    p.addQuadCurve(to: a1, control: bend)
                    c.stroke(p, with: .color(ink((0.6, 1.0, 0.75), 0.2 * peak * pow(1 - tu, 1.4))),
                             style: StrokeStyle(lineWidth: max(0.8, w * 0.006 * (1 + tu)), lineCap: .round))
                }
            }
        }
    }

    // MARK: The reading orbit

    static let bodyAU: [Double] = [0.387, 0.723, 1.0, 1.524, 5.203, 9.537, 19.19, 30.07, 39.48, 17.83]

    static func eccentricAnomaly(_ M: Double, _ e: Double) -> Double {
        var E = e < 0.8 ? M : Double.pi
        for _ in 0..<40 {
            let f = E - e * sin(E) - M
            E -= f / (1 - e * cos(E))
        }
        return E
    }

    /// Your place in the book as a planet's place in its real orbit: true eccentricity and orientation,
    /// and Kepler's second law, so equal amounts of reading sweep out equal areas.
    func orrery(_ ctx: GraphicsContext, t: Double, progress: Double) {
        guard d.body >= 0, d.body < Int(sky_body_count()), let ptr = sky_body_at(Int32(d.body)) else { return }
        let b = ptr.pointee
        let e = b.e
        let a = 0.085
        let varpi = b.varpi * Double.pi / 180
        let retro = b.retrograde != 0
        let cx = Double(d.orreryCenter.x), cy = Double(d.orreryCenter.y)
        let sunX = cx + a * e * cos(varpi), sunY = cy - a * e * sin(varpi)
        let minor = (1 - e * e).squareRoot()
        func orbitPoint(_ E: Double) -> CGPoint {
            let x = cos(E) - e
            var y = minor * sin(E)
            if retro { y = -y }
            let rx = x * cos(varpi) - y * sin(varpi)
            let ry = x * sin(varpi) + y * cos(varpi)
            return pt(sunX + rx * a, sunY - ry * a)
        }
        var orbit = Path()
        for i in 0...72 {
            let q = orbitPoint(Double(i) / 72 * CV.tau)
            if i == 0 { orbit.move(to: q) } else { orbit.addLine(to: q) }
        }
        orbit.closeSubpath()
        let bodyCol: RGB01 = (Double(b.r), Double(b.g), Double(b.b))
        let lineCol: RGB01 = dark ? (0.85, 0.88, 1.0) : pal.ink01
        ctx.stroke(orbit, with: .color(skyColor(lineCol, dark ? 0.16 : 0.2)), lineWidth: max(0.5, w * 0.0028))

        var c = ctx
        c.blendMode = dark ? .screen : .normal
        let Ep = CoverPainter.eccentricAnomaly(CV.tau * min(progress, 0.999), e)
        if progress > 0.002 {
            let sun = pt(sunX, sunY)
            var sector = Path()
            sector.move(to: sun)
            var arc = Path()
            let steps = max(2, Int(48 * progress) + 2)
            for i in 0...steps {
                let q = orbitPoint(Ep * Double(i) / Double(steps))
                sector.addLine(to: q)
                if i == 0 { arc.move(to: q) } else { arc.addLine(to: q) }
            }
            sector.closeSubpath()
            c.fill(sector, with: .color(ink(bodyCol, 0.08)))
            c.stroke(arc, with: .color(ink(bodyCol, 0.55)), lineWidth: max(0.7, w * 0.005))
        }
        let sun = pt(sunX, sunY)
        glow(c, sun, w * 0.02, (1.0, 0.85, 0.5), 0.5, raw: dark)
        c.fill(CV.circle(sun, max(0.8, w * 0.0055)), with: .color(ink((1.0, 0.9, 0.6), 0.95)))
        let pulse = 0.85 + 0.15 * sin(CV.tau * t / 5)
        let q = orbitPoint(Ep)
        glow(c, q, w * 0.022, bodyCol, 0.45 * pulse, raw: dark)
        c.fill(CV.circle(q, max(0.8, w * 0.006)), with: .color(ink(CV.mix(bodyCol, (1, 1, 1), 0.3), 0.95)))
    }

    // MARK: The lens

    func lensShadow(_ ctx: GraphicsContext, _ L: Lens) {
        let c = pt(L.center)
        let rE = L.theta * w
        let s = L.strength
        let here = skyAt(Double(L.center.y))
        let core = dark ? CV.mix(here, (0, 0, 0), 0.6) : CV.mix(here, pal.ink01, 0.05)
        ctx.fill(CV.circle(c, rE * 1.6), with: .radialGradient(Gradient(stops: [
            .init(color: skyColor(core, 0.8 * s), location: 0),
            .init(color: skyColor(here, 0.55 * s), location: 0.45),
            .init(color: skyColor(here, 0), location: 1),
        ]), center: c, startRadius: 0, endRadius: rE * 1.6))
    }

    func lensRing(_ ctx: GraphicsContext, _ L: Lens) {
        let c = pt(L.center)
        let rE = L.theta * w
        let s = L.strength
        let col: RGB01 = dark ? (0.85, 0.9, 1.0) : pal.ink01
        var g = ctx
        g.blendMode = dark ? .screen : .normal
        g.stroke(CV.circle(c, rE), with: .color(skyColor(col, 0.22 * s)), lineWidth: max(0.6, rE * 0.09))
        g.stroke(CV.circle(c, rE), with: .color(skyColor(col, 0.07 * s)), lineWidth: max(1.5, rE * 0.35))
    }

    // MARK: Caption

    func shortName(_ name: String) -> String {
        if let r = name.range(of: " · ") { return String(name[r.upperBound...]) }
        return name
    }

    func kindLine(_ o: SkyDSO) -> String {
        switch o.kind {
        case SKY_EMISSION: return "Emission nebula — hydrogen glowing red, lit by young stars inside it"
        case SKY_PILLARS: return "Columns of gas and dust where new stars are forming"
        case SKY_TRIFID: return "Emission, reflection and dark nebula in one"
        case SKY_ROSETTE: return "A hollow blown in a glowing cloud by its central cluster"
        case SKY_REFLECTION: return "Reflection nebula — dust scattering the blue light of nearby stars"
        case SKY_PN_RING, SKY_PN_BIPOLAR: return "Planetary nebula — the shed layers of a dying Sun-like star"
        case SKY_SNR: return "Supernova remnant — the expanding debris of an exploded star"
        case SKY_GALAXY: return "A galaxy of hundreds of billions of stars"
        case SKY_CLUSTER:
            return o.variant == 1 ? "Globular cluster — hundreds of thousands of ancient stars"
                                  : "Open cluster — young stars born together"
        case SKY_DARK: return "Dark nebula — dust blocking the light behind it"
        case SKY_BLACKHOLE:
            return o.variant == 0 ? "The Milky Way's central black hole, 4 million Suns — imaged by the EHT in 2022"
                                  : "The first black hole ever identified (1971), orbiting a blue supergiant every 5.6 days"
        case SKY_PULSAR:
            return o.variant == 0 ? String(format: "The first pulsar found (Jocelyn Bell, 1967) — pulsing every %.4f s, shown in real time", o.period)
                                  : "A neutron star spinning 11 times a second — shown 20× slower"
        case SKY_ECHO: return "Light echo — the 2002 flash spreading through surrounding dust"
        case SKY_COMPLEX: return "Dust and gas lit gold, blue and red by nearby stars"
        default: return ""
        }
    }

    func dsoLine(_ o: SkyDSO) -> String {
        let short = shortName(o.name)
        for fact in d.field.facts where fact.hasPrefix(o.name) || fact.contains(short) {
            if let r = fact.range(of: " — ") { return String(fact[r.upperBound...]) }
            return fact
        }
        if !o.detail.isEmpty { return o.detail }
        return kindLine(o)
    }

    func dsoNear(_ q: CGPoint) -> SkyDSO? {
        var best: SkyDSO?
        var bestDistance = Double.infinity
        for o in d.field.dsos {
            let reach = max(0.045, radius(o) / w * 1.1)
            let dd = CV.dist(o.p, q)
            if dd < reach && dd < bestDistance {
                best = o
                bestDistance = dd
            }
        }
        return best
    }

    func starNear(_ q: CGPoint, t: Double) -> SkyStar? {
        var best: SkyStar?
        var bestDistance = Double.infinity
        for s in d.field.stars where s.mag < 5.5 {
            let dd = CV.dist(starPoint(s, t), q)
            let reach = s.name != nil ? 0.06 : 0.03
            if dd < reach && dd < bestDistance {
                best = s
                bestDistance = dd
            }
        }
        return best
    }

    func starLine(_ s: SkyStar) -> String {
        var parts: [String] = []
        let ly = CV.lightYears(s.ly)
        if !ly.isEmpty { parts.append(ly) }
        if let desc = s.desc, !desc.isEmpty { parts.append(desc) }
        switch s.variable {
        case 1: parts.append("eclipsed by its companion every 2 d 21 h (sped up here)")
        case 2: parts.append("swells and fades every 332 days (sped up here)")
        case 3: parts.append("the first Cepheid, pulsing every 5.37 days (sped up)")
        case 4: parts.append("its Great Dimming of 2019–20 replays now and then")
        case 5: parts.append("the sky turns around it once every 23 h 56 min")
        default: break
        }
        if let left = CV.departure(s.ly) { parts.append(left) }
        return parts.joined(separator: " · ")
    }

    func planetNear(_ q: CGPoint, sky: SkyNow) -> SkyPlanet? {
        for pl in sky.planets where pl.visible {
            guard let p0 = d.field.project(ra: pl.ra, dec: pl.dec) else { continue }
            if CV.dist(p0, q) < 0.05 { return pl }
        }
        return nil
    }

    func planetLine(_ pl: SkyPlanet) -> String {
        var s = String(format: "Its real position tonight · magnitude %.1f", pl.mag)
        if let p0 = d.field.project(ra: pl.ra, dec: pl.dec) {
            if let o = d.field.dsos.min(by: { CV.dist($0.p, p0) < CV.dist($1.p, p0) }), CV.dist(o.p, p0) < 0.12 {
                s += " · beside the \(shortName(o.name))"
            } else if let st = d.field.stars.filter({ $0.name != nil }).min(by: { CV.dist($0.p, p0) < CV.dist($1.p, p0) }),
                      CV.dist(st.p, p0) < 0.12, let n = st.name {
                s += " · near \(n)"
            }
        }
        return s + " · planets shine steadily; stars twinkle"
    }

    func relative(_ date: Date) -> String {
        let hours = date.timeIntervalSinceNow / 3600
        if hours < 1 { return "within the hour" }
        if hours < 48 { return CV.dayTime.string(from: date) }
        return "on " + CV.dayMonth.string(from: date)
    }

    func moonLine(_ sky: SkyNow) -> String {
        let pct = Int((sky.moonIllum * 100).rounded())
        let next = sky.waxing ? sky.nextFull : sky.nextNew
        let label = sky.waxing ? "full Moon" : "new Moon"
        return "\(sky.moonPhaseName) · \(pct)% lit · \(label) \(relative(next))"
    }

    func periodDays(_ text: String) -> Double {
        let number = Double(text.split(separator: " ").first.map(String.init) ?? "") ?? 365.25
        return text.contains("year") ? number * 365.25 : number
    }

    func orreryLines(_ progress: Double) -> (String, String) {
        guard let ptr = sky_body_at(Int32(d.body)) else { return ("", "") }
        let b = ptr.pointee
        let name = String(cString: b.name)
        let periodText = String(cString: b.period)
        let pct = Int((progress * 100).rounded())
        let E = CoverPainter.eccentricAnomaly(CV.tau * min(progress, 0.999), b.e)
        let au = (d.body < CoverPainter.bodyAU.count ? CoverPainter.bodyAU[d.body] : 1) * (1 - b.e * cos(E))
        let days = periodDays(periodText) * progress
        let when = days < 700 ? "day \(Int(days.rounded()))" : String(format: "year %.1f", days / 365.25)
        let orbitName = periodText.replacingOccurrences(of: " days", with: "-day").replacingOccurrences(of: " years", with: "-year")
        let detail = "\(pct)% read — \(when) of its \(orbitName) orbit, \(String(format: "%.2f", au)) AU from the Sun. "
            + "Equal reading sweeps equal areas, as Kepler found."
        return ("Your orbit · \(name)", detail)
    }

    func tonightLine(sky: SkyNow, kp: Double) -> String {
        var items: [String] = []
        if let e = sky.eclipseToday { items.append("\(e.title) today") }
        for i in d.field.showers where i < sky.showerZHR.count && i < SkyShowerInfo.all.count && sky.showerZHR[i] > 0 {
            let s = SkyShowerInfo.all[i]
            items.append("\(s.name) active (peak \(s.peak), \(Int(s.speed)) km/s, from \(s.parent))")
        }
        let here = sky.planets.filter { pl in
            guard pl.visible, let p = d.field.project(ra: pl.ra, dec: pl.dec) else { return false }
            return p.x > 0 && p.x < 1 && p.y > 0 && Double(p.y) < units
        }
        if !here.isEmpty {
            items.append(here.map { $0.name }.joined(separator: " and ") + (here.count == 1 ? " is here" : " are here"))
        }
        if d.field.aurora != 0 {
            let live = SpaceWeather.shared.updated.map { abs($0.timeIntervalSinceNow) < 3 * 3600 } ?? false
            let kind = d.field.aurora > 0 ? "borealis" : "australis"
            items.append(String(format: "aurora %@ at Kp %.1f", kind, kp) + (live ? " (NOAA, live)" : ""))
        }
        if items.count < 2 {
            items.append("Moon \(Int((sky.moonIllum * 100).rounded()))% lit")
        }
        return "Tonight: " + items.prefix(2).joined(separator: " · ")
    }

    func caption(at q: CGPoint, visits: Int, t: Double, sky: SkyNow, kp: Double, progress: Double, ev: CoverEvents) -> (String, String, String) {
        let f = d.field
        var title = f.name
        var detail = ""
        if let e = ev.eclipse, d.hasMoon, CV.dist(d.moonCenter, q) < d.moonD * 0.85 {
            title = e.title
            detail = e.detail
        } else if let c = ev.comet, CV.dist(cometHead(c), q) < 0.2, let ptr = sky_comet_at(Int32(c.index)) {
            title = String(cString: ptr.pointee.title)
            detail = String(cString: ptr.pointee.detail)
        } else if let fp = d.flarePoint, f.flare >= 0, CV.dist(fp, q) < (ev.flare != nil ? 0.16 : 0.07),
                  let ptr = sky_flare_at(Int32(f.flare)) {
            title = String(cString: ptr.pointee.title)
            detail = String(cString: ptr.pointee.detail)
        } else if d.hasMoon, CV.dist(d.moonCenter, q) < d.moonD * 0.55 {
            title = "The Moon tonight"
            detail = moonLine(sky)
        } else if CV.dist(d.orreryCenter, q) < 0.1 {
            (title, detail) = orreryLines(progress)
        } else if let pl = planetNear(q, sky: sky) {
            title = "\(pl.name), tonight"
            detail = planetLine(pl)
        } else if let o = dsoNear(q) {
            title = o.name
            detail = dsoLine(o)
        } else if let s = starNear(q, t: t) {
            title = s.name ?? "A star in \(f.name)"
            detail = starLine(s)
        } else {
            let lens = f.lens.isEmpty
                ? "Gravitational lensing — the pointer bends starlight like a mass would, into arcs and an Einstein ring"
                : "Gravitational lens · " + f.lens
            let pool = f.facts + [lens]
            detail = pool[max(0, visits) % pool.count]
        }
        return (title, detail, tonightLine(sky: sky, kp: kp))
    }

    func paintCaption(_ ctx: GraphicsContext, _ lines: (String, String, String), alpha: Double) {
        guard alpha > 0.01 else { return }
        let W = Double(size.width)
        let pad = W * 0.07
        let maxW = W - 2 * pad
        let inkColor: Color = dark ? Color.white : CoverPalette.rgb(pal.ink)
        let fs1 = max(8.5, W * 0.066), fs2 = max(7.5, W * 0.05)
        var t1 = ctx.resolve(Text(lines.0).font(.system(size: fs1, weight: .semibold, design: .serif)))
        t1.shading = .color(inkColor.opacity(0.96 * alpha))
        var t2 = ctx.resolve(Text(lines.1).font(.system(size: fs2, weight: .regular, design: .serif)))
        t2.shading = .color(inkColor.opacity(0.86 * alpha))
        var t3 = ctx.resolve(Text(lines.2).font(.system(size: fs2 * 0.95, weight: .regular, design: .serif).italic()))
        t3.shading = .color(inkColor.opacity(0.66 * alpha))
        let box = CGSize(width: maxW, height: Double(size.height))
        let s1 = t1.measure(in: box), s2 = t2.measure(in: box), s3 = t3.measure(in: box)
        let gap = W * 0.018
        let h1 = Double(s1.height), h2 = Double(s2.height), h3 = Double(s3.height)
        let scrimH = pad + h1 + gap + h2 + gap + h3 + pad * 1.6
        let base = dark ? CoverPalette.rgb(pal.bottom, 0.86 * alpha) : Color.white.opacity(0.84 * alpha)
        let clear = dark ? CoverPalette.rgb(pal.bottom, 0) : Color.white.opacity(0)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: scrimH)),
                 with: .linearGradient(Gradient(stops: [.init(color: base, location: 0), .init(color: base, location: 0.72),
                                                        .init(color: clear, location: 1)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: scrimH)))
        var y = pad
        ctx.draw(t1, in: CGRect(x: pad, y: y, width: maxW, height: h1))
        y += h1 + gap
        ctx.draw(t2, in: CGRect(x: pad, y: y, width: maxW, height: h2))
        y += h2 + gap
        ctx.draw(t3, in: CGRect(x: pad, y: y, width: maxW, height: h3))
    }
}
