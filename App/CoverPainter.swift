import SwiftUI

// Paints the still part of the covers, and writes their captions. Everything is grounded in the real sky:
// the sky colour, the Milky Way from its real outline, zodiacal light along the real ecliptic, and each
// deep-sky object drawn after its real structure.
//
// What moves — stars, planets, the Moon, eclipses, comets, meteors, aurora, the reading orbit and the
// lens under the pointer — is laid out in CoverScene and drawn on the GPU (CoverMetal, CoverShaders).

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

    // MARK: Geometry shared with the moving sky (CoverScene)

    // Eclipses

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

    // Stars

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

    func starRadius(_ mag: Double) -> Double {
        let b = pow(10, -0.4 * (mag - 6.5))
        return max(0.35, w * 0.0028 * pow(b, 0.22))
    }

    // Comets

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

    // The reading orbit

    static let bodyAU: [Double] = [0.387, 0.723, 1.0, 1.524, 5.203, 9.537, 19.19, 30.07, 39.48, 17.83]

    static func eccentricAnomaly(_ M: Double, _ e: Double) -> Double {
        var E = e < 0.8 ? M : Double.pi
        for _ in 0..<40 {
            let f = E - e * sin(E) - M
            E -= f / (1 - e * cos(E))
        }
        return E
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
