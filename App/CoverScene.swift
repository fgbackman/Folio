import Foundation
import simd

// One frame of a cover's moving sky, as a list of shapes for the GPU. The stars come straight from
// the catalogue buffer; everything else — the Moon, eclipses, comets, meteors, aurora, the reading
// orbit, the lens — is a few dozen shapes laid out here from the same real data as before.

typealias V2 = SIMD2<Float>
typealias V4 = SIMD4<Float>
typealias P2 = SIMD2<Double>

// These mirror the structs in CoverShaders.
struct CoverPrim { var a: V4, b: V4, c0: V4, c1: V4, p: V4 }
struct CoverVertex { var pos: V2, edge: V2, color: V4 }
struct CoverStar { var s0: V4, s1: V4, s2: V4 }

struct CoverUniforms {
    var size = V2(0, 0)
    var scale: Float = 1
    var w: Float = 1
    var t: Float = 0
    var night: Float = 0
    var dark: Float = 0
    var lensStrength: Float = 0
    var lensCenter = V2(0, 0)
    var lensTheta: Float = 0
    var dimming: Float = 0
    var drift = V2(0, 0)
    var starPass: Float = 0
    var units: Float = 1.5
    var ink = V4(0, 0, 0, 1)
}

struct MoonUniforms {
    var center = V2(0, 0)
    var R: Float = 0
    var k: Float = 0
    var side: Float = 1
    var stage: Float = 0
    var lib = V2(0, 0)
    var disc = V4(0, 0, 0, 0)
    var es: Float = 0
    var eclipse: Float = 0
    var fade: Float = 0
    var pad: Float = 0
    var shadow = V2(0, 0)
    var pad2 = V2(0, 0)
    var rays0 = V4(0, 0, 0, 0), rays1 = V4(0, 0, 0, 0), rays2 = V4(0, 0, 0, 0)
}

enum CoverBlend { case normal, screen }

final class CoverScene {
    enum Kind: Equatable { case prims, mesh, stars, moon(Int) }
    struct Batch {
        var kind: Kind
        var blend: CoverBlend
        var start: Int
        var count: Int
    }

    var prims: [CoverPrim] = []
    var verts: [CoverVertex] = []
    var batches: [Batch] = []
    var uniforms = CoverUniforms()
    var moon = MoonUniforms()

    func reset() {
        prims.removeAll(keepingCapacity: true)
        verts.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        uniforms = CoverUniforms()
        moon = MoonUniforms()
    }

    private func extend(_ kind: Kind, _ blend: CoverBlend, start: Int, count: Int) {
        if let last = batches.last, last.kind == kind, last.blend == blend, last.start + last.count == start {
            batches[batches.count - 1].count += count
        } else {
            batches.append(Batch(kind: kind, blend: blend, start: start, count: count))
        }
    }

    func add(_ p: CoverPrim, _ blend: CoverBlend) {
        prims.append(p)
        extend(.prims, blend, start: prims.count - 1, count: 1)
    }

    func triangle(_ a: CoverVertex, _ b: CoverVertex, _ c: CoverVertex, _ blend: CoverBlend) {
        verts.append(a)
        verts.append(b)
        verts.append(c)
        extend(.mesh, blend, start: verts.count - 3, count: 3)
    }

    func stars(_ blend: CoverBlend) { batches.append(Batch(kind: .stars, blend: blend, start: 0, count: 0)) }
    func moonStage(_ stage: Int, _ blend: CoverBlend) { batches.append(Batch(kind: .moon(stage), blend: blend, start: 0, count: 0)) }
}

extension CoverDesign {
    /// Lays out the moving sky for one frame. `t` is zero when covers are set not to animate.
    func compose(into scene: CoverScene, size: CGSize, scale: Double, t: Double, sky: SkyNow, kp: Double,
                 progress: Double, bookmarks: Int, hover: HoverInfo?) {
        scene.reset()
        guard size.width > 2, size.height > 2 else { return }
        let p = LivePainter(self, size, scale, scene)
        let progress = progress.isFinite ? CV.clamp(progress) : 0
        let ev = events(t: t, sky: sky)
        let night = p.cp.nightFactor(ev)
        let solar = ev.eclipse.map { [0, 1, 4].contains($0.kind) } ?? false
        var lens: Lens?
        if let h = hover, size.width >= 100 {
            lens = Lens(center: h.point, theta: 0.05, strength: h.strength)
        }

        let (ux, uy) = p.cp.drift(1, t)
        var u = CoverUniforms()
        u.size = V2(Float(size.width), Float(size.height))
        u.scale = Float(scale)
        u.w = Float(p.w)
        u.t = Float(t.truncatingRemainder(dividingBy: 86400))     // a whole number of every variable star's cycle
        u.night = Float(night)
        u.dark = palette.dark ? 1 : 0
        u.dimming = Float(ev.dimming)
        u.drift = V2(Float(ux), Float(uy))
        u.units = Float(p.cp.units)
        u.ink = V4(Float(palette.ink01.0), Float(palette.ink01.1), Float(palette.ink01.2), 1)
        if let L = lens {
            u.lensStrength = Float(L.strength)
            u.lensCenter = V2(Float(L.center.x), Float(L.center.y))
            u.lensTheta = Float(L.theta)
        }
        scene.uniforms = u

        p.eclipseSky(night: night, solar: solar)
        p.orbs(t: t)
        p.aurora(t: t, kp: kp)
        p.deepSkyLive(t: t)
        if let L = lens { p.lensShadow(L) }
        p.trails(t: t)
        p.figure(t: t, bookmarks: bookmarks)
        scene.stars(p.glowBlend)
        p.planets(t: t, sky: sky, night: night)
        if let f = ev.flare { p.flare(t: t, f) }
        if let c = ev.comet { p.comet(c) }
        p.moon(t: t, sky: sky, ev: ev)
        p.meteors(t: t, sky: sky)
        p.orrery(t: t, progress: progress)
        if let L = lens { p.lensRing(L) }
    }
}

struct LivePainter {
    let d: CoverDesign
    let cp: CoverPainter         // shares the geometry of the painted layer
    let scene: CoverScene
    let w: Double                // points per cover unit
    let px: Double               // one pixel, in points
    let dark: Bool
    let pal: CoverPalette
    let size: CGSize

    init(_ d: CoverDesign, _ size: CGSize, _ scale: Double, _ scene: CoverScene) {
        self.d = d
        self.cp = CoverPainter(d, size)
        self.scene = scene
        self.w = Double(size.width)
        self.px = 1 / max(1, scale)
        self.dark = d.palette.dark
        self.pal = d.palette
        self.size = size
    }

    /// Light adds to a night sky; on a twilight one it is laid on like ink.
    var glowBlend: CoverBlend { dark ? .screen : .normal }

    func pt(_ x: Double, _ y: Double) -> P2 { P2(x * w, y * w) }
    func pt(_ p: CGPoint) -> P2 { P2(Double(p.x) * w, Double(p.y) * w) }
    func f2(_ p: P2) -> V2 { V2(Float(p.x), Float(p.y)) }

    // MARK: Colours

    func raw(_ c: RGB01, _ a: Double) -> V4 { V4(Float(c.0), Float(c.1), Float(c.2), Float(CV.clamp(a))) }

    /// Nebula colour: glowing light on night skies, a soft watercolour stain on twilight ones.
    func neb(_ c: RGB01, _ a: Double) -> V4 { dark ? raw(c, a) : raw(CV.mix(c, pal.ink01, 0.38), a * 0.66) }

    /// Light on night skies, ink on twilight ones.
    func ink(_ c: RGB01, _ a: Double) -> V4 { dark ? raw(c, a) : raw(CV.mix(c, pal.ink01, 0.65), a * 0.85) }

    // MARK: Shapes

    func glow(_ p: P2, _ r: Double, _ c: RGB01, _ a: Double, raw isRaw: Bool = false, _ blend: CoverBlend) {
        guard r > 0.05, a > 0.002 else { return }
        scene.add(CoverPrim(a: V4(Float(p.x), Float(p.y), Float(r), Float(r)), b: V4(0, 0, 0, 0),
                            c0: isRaw ? raw(c, a) : neb(c, a), c1: V4(0, 0, 0, 0), p: V4(0, 0, 0, 0)), blend)
    }

    func disc(_ p: P2, _ r: Double, _ color: V4, _ blend: CoverBlend) {
        scene.add(CoverPrim(a: V4(Float(p.x), Float(p.y), Float(r), Float(r)), b: V4(0, 1, 0, 0),
                            c0: color, c1: color, p: V4(0, 0, 0, 0)), blend)
    }

    /// A disc fading evenly from one colour at the centre to another at the rim.
    func fade(_ p: P2, _ r: Double, _ inner: V4, _ outer: V4, _ blend: CoverBlend) {
        scene.add(CoverPrim(a: V4(Float(p.x), Float(p.y), Float(r), Float(r)), b: V4(0, 2, 0, 0),
                            c0: inner, c1: outer, p: V4(0, 0, 0, 0)), blend)
    }

    func ring(_ p: P2, _ r: Double, _ lineWidth: Double, _ color: V4, _ blend: CoverBlend) {
        guard r > 0 else { return }
        scene.add(CoverPrim(a: V4(Float(p.x), Float(p.y), Float(r), Float(lineWidth)), b: V4(0, 3, 0, 0),
                            c0: color, c1: color, p: V4(0, 0, 0, 0)), blend)
    }

    /// A straight line with round ends, shading from `c0` at `a` to `c1` at `b`
    /// (or, with `centred`, from `c0` in the middle to `c1` at both ends).
    func line(_ a: P2, _ b: P2, _ lineWidth: Double, _ c0: V4, _ c1: V4, centred: Bool = false, _ blend: CoverBlend) {
        scene.add(CoverPrim(a: V4(Float(a.x), Float(a.y), Float(b.x), Float(b.y)),
                            b: V4(0, 4, Float(lineWidth), centred ? 1 : 0), c0: c0, c1: c1, p: V4(0, 0, 0, 0)), blend)
    }

    func spikes(_ q: P2, _ len: Double, _ color: V4, _ width: Double, _ blend: CoverBlend) {
        guard len > 0.5 else { return }
        var clear = color
        clear.w = 0
        line(P2(q.x - len, q.y), P2(q.x + len, q.y), max(0.3, width), color, clear, centred: true, blend)
        line(P2(q.x, q.y - len), P2(q.x, q.y + len), max(0.3, width), color, clear, centred: true, blend)
    }

    func vertex(_ p: P2, _ color: V4, across: Double = 0, half: Double = 0) -> CoverVertex {
        CoverVertex(pos: f2(p), edge: V2(Float(across), Float(half)), color: color)
    }

    /// A stroked path with feathered sides.
    func stroke(_ pts: [P2], _ lineWidth: Double, closed: Bool = false, _ blend: CoverBlend, color: (Int) -> V4) {
        let n = pts.count
        guard n > 1 else { return }
        let half = lineWidth / 2 + px / 2
        var left: [CoverVertex] = [], right: [CoverVertex] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        for i in 0..<n {
            let before = i > 0 ? pts[i - 1] : (closed ? pts[n - 1] : pts[i])
            let after = i < n - 1 ? pts[i + 1] : (closed ? pts[0] : pts[i])
            var dir = after - before
            let len = simd_length(dir)
            dir = len > 1e-9 ? dir / len : P2(1, 0)
            let normal = P2(-dir.y, dir.x) * half
            let c = color(i)
            left.append(vertex(pts[i] + normal, c, across: -1, half: half))
            right.append(vertex(pts[i] - normal, c, across: 1, half: half))
        }
        for i in 0..<(closed ? n : n - 1) {
            let j = (i + 1) % n
            scene.triangle(left[i], right[i], left[j], blend)
            scene.triangle(right[i], right[j], left[j], blend)
        }
    }

    /// A band between two edges that may widen or narrow, feathered along both.
    func ribbon(_ left: [P2], _ right: [P2], _ blend: CoverBlend, color: (Int) -> V4) {
        let n = min(left.count, right.count)
        guard n > 1 else { return }
        var l: [CoverVertex] = [], r: [CoverVertex] = []
        for i in 0..<n {
            let half = max(px, simd_length(left[i] - right[i]) / 2)
            let c = color(i)
            l.append(vertex(left[i], c, across: -1, half: half))
            r.append(vertex(right[i], c, across: 1, half: half))
        }
        for i in 0..<(n - 1) {
            scene.triangle(l[i], r[i], l[i + 1], blend)
            scene.triangle(r[i], r[i + 1], l[i + 1], blend)
        }
    }

    func quadCurve(_ a: P2, _ control: P2, _ b: P2, steps: Int = 12) -> [P2] {
        (0...steps).map { i in
            let s = Double(i) / Double(steps)
            return a * ((1 - s) * (1 - s)) + control * (2 * s * (1 - s)) + b * (s * s)
        }
    }

    /// An ellipse shaded outward through colour stops (the first stop is the centre).
    func radial(_ c: P2, _ rx: Double, _ ry: Double, stops: [(Double, V4)], _ blend: CoverBlend) {
        guard stops.count > 1 else { return }
        let segments = 40
        func point(_ i: Int, _ loc: Double) -> P2 {
            let a = Double(i) / Double(segments) * CV.tau
            return P2(c.x + cos(a) * rx * loc, c.y + sin(a) * ry * loc)
        }
        for i in 0..<segments {
            for s in 1..<stops.count {
                let (l0, c0) = stops[s - 1], (l1, c1) = stops[s]
                let a = vertex(point(i, l0), c0), b = vertex(point(i + 1, l0), c0)
                let e = vertex(point(i, l1), c1), f = vertex(point(i + 1, l1), c1)
                if l0 > 0 { scene.triangle(a, b, e, blend) }
                scene.triangle(b, f, e, blend)
            }
        }
    }

    func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, top: V4, bottom: V4, _ blend: CoverBlend) {
        let a = vertex(P2(x0, y0), top), b = vertex(P2(x1, y0), top)
        let c = vertex(P2(x0, y1), bottom), e = vertex(P2(x1, y1), bottom)
        scene.triangle(a, b, c, blend)
        scene.triangle(b, e, c, blend)
    }

    // MARK: Eclipses — sky

    func eclipseSky(night: Double, solar: Bool) {
        guard night > 0.005 else { return }
        let W = Double(size.width), H = Double(size.height)
        let shade = raw((0.03, 0.04, 0.09), (dark ? 0.35 : 0.72) * night)
        rect(0, 0, W, H, top: shade, bottom: shade, .normal)
        if solar {
            // a sunset all round the horizon: beyond the Moon's shadow the air is still sunlit
            rect(0, H * 0.6, W, H, top: raw((1.0, 0.55, 0.3), 0), bottom: raw((1.0, 0.55, 0.3), 0.35 * night), .normal)
        }
    }

    // MARK: Mist

    func orbs(t: Double) {
        let k = dark ? 0.3 : 0.85
        for o in d.orbs {
            let x = o.x + o.driftX * sin(CV.tau * t / o.periodX + o.phaseX)
            let y = o.y + o.driftY * sin(CV.tau * t / o.periodY + o.phaseY)
            let r = o.r * (1 + o.breath * sin(CV.tau * t / o.breathPeriod + o.breathPhase)) * w
            let c: RGB01 = (o.color.0 / 255, o.color.1 / 255, o.color.2 / 255)
            fade(pt(x, y), r, raw(c, o.opacity * k), raw(c, 0), glowBlend)
        }
    }

    // MARK: Aurora

    /// Aurora on the polar constellations, as strong as the live planetary K-index:
    /// green oxygen (557.7 nm) low down, red oxygen (630 nm) high up in strong storms,
    /// and a violet nitrogen fringe (427.8 nm) along the lower edge when it is very active.
    func aurora(t: Double, kp: Double) {
        guard d.field.aurora != 0, dark else { return }
        let a = CV.clamp((kp - 0.5) / 6.5, 0.18, 1)
        let n = 34
        let x0 = -0.05, x1 = 1.05
        let strip = (x1 - x0) / Double(n)
        for i in 0..<n {
            let x = x0 + (Double(i) + 0.5) * strip
            let base = 1.14 + 0.07 * sin(CV.tau * (x * 0.9 + t / 41)) + 0.035 * sin(CV.tau * (x * 2.3 - t / 23))
            let height = (0.22 + 0.4 * a) * (0.65 + 0.35 * sin(CV.tau * (x * 1.7 + t / 31) + 1.3))
            let ray = 0.55 + 0.45 * sin(CV.tau * (x * 7.3 + t / 9) + Double(i) * 0.7)
            let top = (base - height) * w, tall = (height + 0.03) * w
            let left = (x - strip * 0.75) * w, right = left + strip * 1.5 * w
            let stops: [(Double, V4)] = [
                (0, raw(SkyInk.auroraRed, 0)),
                (0.18, raw(SkyInk.auroraRed, 0.22 * a * a * ray)),
                (0.45, raw(SkyInk.auroraGreen, 0.12 * a * ray)),
                (0.9, raw(SkyInk.auroraGreen, 0.42 * a * ray)),
                (0.96, raw(SkyInk.auroraViolet, 0.25 * max(0, a - 0.55) * ray)),
                (1, raw(SkyInk.auroraViolet, 0)),
            ]
            for s in 1..<stops.count {
                rect(left, top + tall * stops[s - 1].0, right, top + tall * stops[s].0,
                     top: stops[s - 1].1, bottom: stops[s].1, .screen)
            }
        }
    }

    // MARK: Deep-sky objects — what moves

    func deepSkyLive(t: Double) {
        let B = glowBlend
        for (i, o) in d.field.dsos.enumerated() {
            let R = cp.radius(o)
            let c = pt(o.p)
            let phase = Double(i) * 1.7
            let breathe = 0.5 + 0.5 * sin(CV.tau * t / 11 + phase)
            switch o.kind {
            case SKY_EMISSION, SKY_TRIFID, SKY_ROSETTE, SKY_COMPLEX:
                glow(c, R * 0.75, SkyInk.hAlpha, 0.04 + 0.05 * breathe, B)
            case SKY_PILLARS:
                // the pillar tips glow where the cluster's ultraviolet light is boiling them away
                for col in CoverPainter.pillarTable {
                    let tip = cp.pillarTip(col, R)
                    glow(P2(c.x + Double(tip.x), c.y + Double(tip.y)), R * 0.18, (1.0, 0.85, 0.6), 0.1 + 0.1 * breathe, B)
                }
            case SKY_PN_RING, SKY_PN_BIPOLAR:
                // the shell keeps expanding at about 20 km/s; a faint halo drifts outward
                let u = (t / 24 + phase).truncatingRemainder(dividingBy: 1)
                ring(c, R * (0.9 + 0.5 * u), max(0.4, R * 0.05), neb(SkyInk.oxygen, 0.1 * (1 - u)), B)
                let tw = 0.75 + 0.25 * sin(CV.tau * t / 3.1 + phase)
                glow(c, R * 0.16, (0.9, 0.95, 1.0), 0.35 * tw, raw: dark, B)
            case SKY_SNR:
                if o.variant == 0 {
                    // the Crab Pulsar flashes 30 times a second; shown 100 times slower
                    pulsar(c, R, period: max(0.001, o.period) * 100, t: t, beams: false)
                } else {
                    let u = (t / 30 + phase).truncatingRemainder(dividingBy: 1)
                    ring(c, R * (0.7 + 0.4 * u), max(0.5, R * 0.06), neb(SkyInk.oxygen, 0.08 * sin(Double.pi * u)), B)
                }
            case SKY_GALAXY:
                glow(c, R * 0.3, SkyInk.warm, 0.06 + 0.07 * breathe, B)
                if o.variant == 3 { jetKnots(c, o, R, t: t) }
            case SKY_BLACKHOLE:
                if o.variant == 0 { photonRing(c, R, t: t) } else { cygnusX1(c, R, t: t) }
            case SKY_PULSAR:
                // PSR B1919+21 pulses at its true period; the Vela pulsar (11 a second) is slowed 20 times
                let period = o.variant == 0 ? o.period : o.period * 20
                pulsar(c, R, period: max(0.05, period), t: t, beams: true)
            case SKY_ECHO:
                lightEcho(c, R, t: t)
            default:
                break
            }
        }
    }

    func pulsar(_ c: P2, _ R: Double, period: Double, t: Double, beams: Bool) {
        let B = glowBlend
        let ph = (t / period).truncatingRemainder(dividingBy: 1)
        let d0 = (ph - 0.5) / 0.12
        let pulse = exp(-d0 * d0)
        let col: RGB01 = (0.75, 0.85, 1.0)
        glow(c, R * (0.25 + 0.35 * pulse), col, 0.22 + 0.55 * pulse, raw: dark, B)
        disc(c, max(0.5, R * 0.05), ink((0.95, 0.97, 1.0), 0.9), B)
        guard beams else { return }
        let ca = cos(ph * CV.tau), sa = sin(ph * CV.tau)
        func turned(_ x: Double, _ y: Double) -> P2 { P2(c.x + x * ca - y * sa, c.y + x * sa + y * ca) }
        for s in [-1.0, 1.0] {
            scene.triangle(vertex(c, ink(col, 0.18)), vertex(turned(s * R * 1.1, -R * 0.16), ink(col, 0)),
                           vertex(turned(s * R * 1.1, R * 0.16), ink(col, 0)), B)
        }
    }

    /// Sagittarius A*, as the Event Horizon Telescope imaged it: a ring of hot gas around the black hole's
    /// shadow, brighter where the gas moves toward us. Hot spots circle it (here once every 40 seconds).
    func photonRing(_ c: P2, _ R: Double, t: Double) {
        let B = glowBlend
        ring(c, R * 0.62, max(0.8, R * 0.26), raw((1.0, 0.55, 0.22), 0.42), B)
        let spin = t * CV.tau / 40
        let colors = [raw((1.0, 0.88, 0.6), 0.85), raw((1.0, 0.55, 0.2), 0.08), raw((1.0, 0.7, 0.4), 0.3), raw((1.0, 0.88, 0.6), 0.85)]
        let n = 72
        let pts = (0..<n).map { i -> P2 in
            let a = spin + Double(i) / Double(n) * CV.tau
            return P2(c.x + cos(a) * R * 0.62, c.y + sin(a) * R * 0.62)
        }
        stroke(pts, max(0.6, R * 0.16), closed: true, B) { i in
            let f = Double(i) / Double(n) * 3
            let k = min(2, Int(f))
            return simd_mix(colors[k], colors[k + 1], V4(repeating: Float(f - Double(k))))
        }
    }

    /// Cygnus X-1: a blue supergiant and a black hole of 21 Suns orbiting every 5.6 days (here 40 seconds);
    /// gas torn from the star spirals into a hot accretion disc.
    func cygnusX1(_ c: P2, _ R: Double, t: Double) {
        let B = glowBlend
        let a = t * CV.tau / 40
        let star = P2(c.x + cos(a) * R * 0.45, c.y + sin(a) * R * 0.18)
        let hole = P2(c.x - cos(a) * R * 0.3, c.y - sin(a) * R * 0.12)
        radial(hole, R * 0.32, R * 0.32 * 0.35, stops: [(0, raw((1.0, 0.95, 0.85), 0.75)), (0.5, raw((1.0, 0.6, 0.3), 0.45)),
                                                        (1, raw((1.0, 0.4, 0.2), 0))], B)
        let mid = (star + hole) / 2
        let stream = raw((0.75, 0.82, 1.0), 0.3)
        stroke(quadCurve(star, P2(mid.x, mid.y - R * 0.15), hole), max(0.4, R * 0.04), B) { _ in stream }
        glow(star, R * 0.32, (0.7, 0.8, 1.0), 0.6, raw: dark, B)
        disc(star, max(0.6, R * 0.09), ink((0.85, 0.9, 1.0), 0.95), B)
    }

    /// M87's jet: knots of plasma that appear to move faster than light (an illusion of their near-light speed).
    func jetKnots(_ c: P2, _ o: SkyDSO, _ R: Double, t: Double) {
        for i in 0..<4 {
            let u = (t / 16 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
            let along = u * R * 0.95
            glow(P2(c.x + cos(o.angle) * along, c.y + sin(o.angle) * along), R * 0.07, (0.75, 0.85, 1.0), 0.45 * (1 - u),
                 raw: dark, glowBlend)
        }
    }

    /// V838 Monocerotis, 2002: the flash of its outburst swept outward through the surrounding dust.
    func lightEcho(_ c: P2, _ R: Double, t: Double) {
        let B = glowBlend
        for i in 0..<3 {
            let u = (t / 36 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let rr = R * (0.15 + 0.9 * u)
            let a = sin(Double.pi * u)
            ring(c, rr, max(0.5, R * 0.12 * (1 - u * 0.5)), neb((0.95, 0.65, 0.45), 0.22 * a), B)
            ring(c, rr * 0.92, max(0.4, R * 0.05), neb((0.6, 0.75, 1.0), 0.12 * a), B)
        }
        disc(c, max(0.5, R * 0.05), ink((1.0, 0.45, 0.35), 0.9), B)
    }

    // MARK: Stars

    /// Star trails around the celestial pole, as in a long-exposure photograph: the arcs grow as the
    /// "exposure" lengthens, then fade and start again. The sky turns once every 23 h 56 min.
    func trails(t: Double) {
        let f = d.field
        guard f.pole >= 0, t > 0, dark else { return }
        var pole = f.project(ra: 0, dec: 90)
        if pole == nil && f.pole < f.stars.count { pole = f.stars[f.pole].p }
        guard let center = pole else { return }
        let u = (t / 200 + 0.3).truncatingRemainder(dividingBy: 1)
        let span = 0.7 * CV.smooth(u / 0.75)
        let fading = u < 0.75 ? 1 : 1 - (u - 0.75) / 0.25
        guard span > 0.01 else { return }
        let n = 14
        for s in f.stars where s.mag < 4.6 {
            let dx = Double(s.p.x - center.x), dy = Double(s.p.y - center.y)
            if (dx * dx + dy * dy).squareRoot() < 0.01 { continue }
            let pts = (0...n).map { j -> P2 in
                let a = -span * Double(j) / Double(n)            // earlier positions: turned back the other way
                return pt(Double(center.x) + dx * cos(a) + dy * sin(a), Double(center.y) - dx * sin(a) + dy * cos(a))
            }
            let strength = 0.4 * fading * min(1, (5 - s.mag) / 3)
            let axis = pts[n] - pts[0]
            let reach = max(1e-9, simd_length_squared(axis))
            stroke(pts, max(0.4, cp.starRadius(s.mag) * 0.9), .screen) { j in
                raw(s.rgb, strength * (1 - CV.clamp(simd_dot(pts[j] - pts[0], axis) / reach)))
            }
        }
    }

    /// The constellation figure: a faint ghost, drawn in one line per bookmark (seven complete it).
    func figure(t: Double, bookmarks: Int) {
        let f = d.field
        guard !f.segs.isEmpty else { return }
        let fraction = min(1, Double(max(0, bookmarks)) / 7)
        let lit = Int((Double(f.segs.count) * fraction).rounded(.up))
        var ghost: [(P2, P2)] = [], bright: [(P2, P2)] = []
        let gap = 0.016
        for (i, sg) in f.segs.enumerated() {
            guard sg.0 >= 0, sg.1 >= 0, sg.0 < f.stars.count, sg.1 < f.stars.count else { continue }
            let a = cp.starPoint(f.stars[sg.0], t), b = cp.starPoint(f.stars[sg.1], t)
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > gap * 2.5 else { continue }
            let ux = dx / len, uy = dy / len
            let p0 = pt(Double(a.x) + ux * gap, Double(a.y) + uy * gap)
            let p1 = pt(Double(b.x) - ux * gap, Double(b.y) - uy * gap)
            if i < lit { bright.append((p0, p1)) } else { ghost.append((p0, p1)) }
        }
        let lineColor: RGB01 = dark ? (0.86, 0.9, 1.0) : pal.ink01
        let faint = raw(lineColor, dark ? 0.15 : 0.2)
        for (a, b) in ghost { line(a, b, max(0.5, w * 0.0035), faint, faint, .normal) }
        guard lit > 0 else { return }
        let shimmer = 0.85 + 0.15 * sin(CV.tau * t / 7)
        let warm: RGB01 = dark ? (1.0, 0.9, 0.7) : pal.ink01
        let halo = raw(warm, 0.16 * shimmer), core = raw(warm, 0.5 * shimmer)
        for (a, b) in bright { line(a, b, max(1.5, w * 0.012), halo, halo, glowBlend) }
        for (a, b) in bright { line(a, b, max(0.6, w * 0.004), core, core, glowBlend) }
    }

    /// Tonight's planets, wherever they really are. Planets shine steadily — they don't twinkle.
    func planets(t: Double, sky: SkyNow, night: Double) {
        let B = glowBlend
        let (dx, dy) = cp.drift(1, t)
        for pl in sky.planets where pl.visible {
            guard let p0 = d.field.project(ra: pl.ra, dec: pl.dec) else { continue }
            let p = CGPoint(x: Double(p0.x) + dx, y: Double(p0.y) + dy)
            guard p.x > 0.02, p.x < 0.98, p.y > 0.02, Double(p.y) < cp.units - 0.02 else { continue }
            let q = pt(p)
            let r = max(0.8, cp.starRadius(pl.mag) * 1.1)
            if dark || night > 0.02 {
                let a = dark ? 1.0 : night
                glow(q, r * 4.5, pl.rgb, 0.3 * a, raw: true, B)
                disc(q, r, raw(CV.mix(pl.rgb, (1, 1, 1), 0.35), a), B)
            }
            if !dark && night < 0.98 {
                disc(q, r * 1.15, raw(CV.mix(pl.rgb, pal.ink01, 0.6), 0.75 * (1 - night)), B)
            }
        }
    }

    // MARK: Historic supernovae and novae

    func flare(t: Double, _ fl: CoverEvents.Flare) {
        guard let fp = d.flarePoint, d.field.flare >= 0, let ptr = sky_flare_at(Int32(d.field.flare)) else { return }
        let f = ptr.pointee
        let u = fl.u
        // light curve: a quick rise to peak, then a long fade (slower for Eta Carinae's eruption)
        let rise = 0.08
        let decay = f.kind == 2 ? 0.45 : 0.28
        var b = u < rise ? CV.smooth(u / rise) : exp(-(u - rise) / decay)
        b *= CV.smooth((1 - u) / 0.1)
        let scale = CV.clamp((8 - Double(f.mag)) / 14, 0.25, 1)
        let (dx, dy) = cp.drift(0.05, t)
        let q = pt(Double(fp.x) + dx, Double(fp.y) + dy)
        // supernovae cool from blue-white to orange; novae fade into the red of hydrogen
        let hot: RGB01 = (0.85, 0.9, 1.0)
        let late: RGB01 = f.kind == 0 ? (1.0, 0.62, 0.4) : (1.0, 0.45, 0.45)
        let col = CV.mix(hot, late, CV.clamp((u - rise) / 0.5))
        let B = glowBlend
        let r = w * (0.006 + 0.014 * scale)
        glow(q, r * 7 * b, col, 0.4 * b, raw: dark, B)
        disc(q, max(0.5, r * b), ink(CV.mix(col, (1, 1, 1), 0.6), b), B)
        if dark { spikes(q, r * 9 * b, raw(col, 0.35 * b), max(0.4, r * 0.18), B) }
        if f.kind == 3 {
            for i in 0..<2 {
                ring(q, r * (3 + 10 * u + Double(i) * 3), max(0.5, r * 0.8), ink((0.95, 0.7, 0.5), 0.18 * (1 - u)), B)
            }
        }
    }

    // MARK: Comets

    /// A great comet: a straight blue ion tail streaming directly away from the Sun, a broad curved
    /// dust tail lagging behind its motion, and the comet's own quirks (anti-tail, striae, horns).
    func comet(_ e: CoverEvents.Comet) {
        guard let ptr = sky_comet_at(Int32(e.index)) else { return }
        let cm = ptr.pointee
        let (p0, p1) = cp.cometPath(e)
        let head = cp.cometHead(e)
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

        let B = glowBlend
        let dust = Double(cm.dust), ion = Double(cm.ion), curve = Double(cm.curve)
        let hx = Double(head.x), hy = Double(head.y)
        let headPt = pt(head)

        // Dust tail
        let Ld = 0.18 + 0.42 * dust
        func center(_ s: Double) -> (Double, Double) {
            (hx + ax * Ld * s + lx * curve * Ld * s * s * 0.7, hy + ay * Ld * s + ly * curve * Ld * s * s * 0.7)
        }
        let (ex, ey) = center(1)
        let tailAxis = pt(ex, ey) - headPt
        let tailReach = max(1e-9, simd_length_squared(tailAxis))
        let dustCol: RGB01 = (1.0, 0.95, 0.84)
        for (widthScale, alpha) in [(1.0, 0.28), (0.45, 0.4)] {
            var left: [P2] = [], right: [P2] = []
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
            ribbon(left, right, B) { j in
                let mid = (left[j] + right[j]) / 2
                return ink(dustCol, alpha * env * dust * (1 - CV.clamp(simd_dot(mid - headPt, tailAxis) / tailReach)))
            }
        }
        if cm.striae != 0 {
            // striae: dust released in bursts, fanned out by sunlight pressure
            for i in 0..<7 {
                let s0 = 0.22 + 0.06 * Double(i)
                let (sx, sy) = center(s0)
                let fan = (Double(i) - 3) * 0.05
                let dxs = ax + lx * (curve + fan), dys = ay + ly * (curve + fan)
                line(pt(sx, sy), pt(sx + dxs * Ld * 0.7, sy + dys * Ld * 0.7), max(0.4, w * 0.003),
                     ink(dustCol, 0.22 * env), ink(dustCol, 0), B)
            }
        }

        // Ion tail: gas ionised by sunlight, blown straight back by the solar wind (blue: CO⁺ ions)
        let Li = 0.15 + 0.5 * ion
        let ionCol: RGB01 = (0.5, 0.7, 1.0)
        for (i, off) in [0.0, 0.035, -0.03].enumerated() {
            let ca = cos(off), sa = sin(off)
            let dx = ax * ca - ay * sa, dy = ax * sa + ay * ca
            let len = Li * (1 - 0.2 * Double(i))
            let a0 = (i == 0 ? 0.55 : 0.25) * ion * env
            line(headPt, pt(hx + dx * len, hy + dy * len), max(0.5, w * (i == 0 ? 0.006 : 0.003)),
                 ink(ionCol, a0), ink(ionCol, 0), B)
        }

        // Anti-tail: dust left in the orbital plane, seen edge-on, appearing to point toward the Sun
        if cm.anti != 0 {
            line(headPt, pt(hx - ax * 0.08, hy - ay * 0.08), max(0.5, w * 0.003), ink(dustCol, 0.4 * env), ink(dustCol, 0), B)
        }

        // Coma: green where diatomic carbon fluoresces
        let comaCol: RGB01 = cm.green != 0 ? (0.6, 1.0, 0.7) : (0.85, 0.95, 1.0)
        glow(headPt, w * 0.035, comaCol, 0.75 * env, raw: dark, B)
        if cm.horns != 0 {
            // the "horns" of 12P/Pons–Brooks: a shell of gas thrown off in an outburst, shadowed by a fragment
            let horn = ink(comaCol, 0.45 * env)
            for s in [-1.0, 1.0] {
                let base = pt(hx - ax * 0.01 + lx * s * 0.006, hy - ay * 0.01 + ly * s * 0.006)
                let tip = pt(hx - ax * 0.03 + lx * s * 0.03, hy - ay * 0.03 + ly * s * 0.03)
                let control = pt(hx - ax * 0.035 + lx * s * 0.01, hy - ay * 0.035 + ly * s * 0.01)
                stroke(quadCurve(base, control, tip, steps: 8), max(0.5, w * 0.004), B) { _ in horn }
            }
        }
        disc(headPt, max(0.5, w * 0.004), ink((1, 1, 1), 0.95 * env), B)
    }

    // MARK: The Moon

    static let tychoRays: [Float] = (0..<9).map { Float(CV.hash(UInt64($0), 77)) }

    func moon(t: Double, sky: SkyNow, ev: CoverEvents) {
        guard d.hasMoon else { return }
        let (dx, dy) = cp.drift(1, t)
        let center = pt(Double(d.moonCenter.x) + dx, Double(d.moonCenter.y) + dy)
        let R = d.moonD / 2 * w
        if let e = ev.eclipse {
            switch e.kind {
            case 0, 1, 4: solarEclipse(center, R, e)
            default:
                // the full Moon passes through Earth's shadow
                let g = cp.lunarGeometry(e)
                moonDisc(center, R, illum: 1, waxing: true, t: t, halo: 1 - 0.85 * g.umbra * g.fade, shadow: g)
            }
            return
        }
        moonDisc(center, R, illum: sky.moonIllum, waxing: sky.waxing, t: t, halo: 1, shadow: nil)
    }

    func moonDisc(_ c: P2, _ R: Double, illum k0: Double, waxing: Bool, t: Double, halo: Double, shadow: LunarGeometry?) {
        let k = CV.clamp(k0)
        let skyHere = cp.skyAt(c.y / w)
        // moonlight scattered in the air: a halo, stronger the fuller the Moon
        glow(c, R * 2.6, dark ? (0.86, 0.9, 1.0) : (1, 1, 1), (dark ? 0.22 : 0.3) * (0.12 + 0.88 * k) * halo, raw: true, glowBlend)

        var m = MoonUniforms()
        m.center = f2(c)
        m.R = Float(R)
        m.k = Float(k)
        m.side = waxing ? 1 : -1
        // libration: the Moon's slow nodding, which lets us see 59% of its surface (sped up here)
        m.lib = V2(Float(0.035 * sin(CV.tau * t / 61)), Float(0.03 * sin(CV.tau * t / 47 + 1)))
        // at night the disc hides the stars behind it; in twilight the night side is lost in the sky
        m.disc = dark ? raw(CV.mix(skyHere, (0, 0, 0), 0.25), 0.94) : raw(CV.mix(skyHere, (1, 1, 1), 0.5), 0.22 * pow(1 - k, 2))
        m.es = Float(0.06 + 0.16 * pow(1 - k, 2))
        let rays = LivePainter.tychoRays
        m.rays0 = V4(rays[0], rays[1], rays[2], rays[3])
        m.rays1 = V4(rays[4], rays[5], rays[6], rays[7])
        m.rays2 = V4(rays[8], 0, 0, 0)
        if let g = shadow {
            m.eclipse = 1
            m.fade = Float(g.fade)
            m.shadow = V2(Float(c.x + g.x * R), Float(c.y + g.y * R))
        }
        scene.moon = m
        scene.moonStage(0, .normal)
        if k < 0.3 { scene.moonStage(1, glowBlend) }
        if k < 0.3 || dark || shadow != nil { scene.moonStage(2, .normal) }
    }

    // MARK: Eclipses — the discs

    func solarEclipse(_ c: P2, _ R: Double, _ e: CoverEvents.Eclipse) {
        let sunR = R * 0.9
        let g = cp.solarGeometry(e)
        let moonC = P2(c.x + g.x * sunR, c.y + g.y * sunR)
        let mR = g.moonR * sunR
        let a = g.fade
        guard a > 0.005 else { return }
        let B = glowBlend

        // the corona — the Sun's million-degree outer atmosphere, seen only in totality
        if g.totality > 0.01 { corona(c, sunR, e, alpha: a * g.totality) }

        // the bright surface minus the Moon (as through a solar filter: orange)
        let filtered = a * (1 - g.totality)
        if filtered > 0.01 {
            glow(c, sunR * 1.9, (1.0, 0.7, 0.35), 0.22 * filtered * (1 - 0.6 * g.coverage), raw: true, B)
            scene.add(CoverPrim(a: V4(Float(c.x), Float(c.y), Float(sunR), Float(sunR)), b: V4(0, 5, 0, 0),
                                c0: raw((1.0, 0.86, 0.55), filtered), c1: raw((1.0, 0.62, 0.25), filtered),
                                p: V4(Float(moonC.x), Float(moonC.y), Float(mR), 0)), .normal)
        }
        // the Moon's silhouette
        disc(moonC, mR, raw((0.02, 0.02, 0.04), a * (0.55 + 0.45 * g.totality)), .normal)
        if e.kind == 0 {
            beads(c, sunR, moonC, g, a)
            if g.totality > 0.01 { prominences(c, sunR, e, a * g.totality) }
        }
        if e.kind == 1 {
            // the ring of fire
            let ringAlpha = a * CV.smooth((0.12 - g.sep) / 0.08)
            if ringAlpha > 0.01 {
                ring(c, sunR * 0.965, max(0.8, sunR * 0.12), raw((1.0, 0.8, 0.5), 0.5 * ringAlpha), B)
                glow(c, sunR * 1.6, (1.0, 0.75, 0.4), 0.25 * ringAlpha, raw: true, B)
            }
        }
    }

    /// At solar minimum the corona stretches into long equatorial streamers with fine polar plumes;
    /// at maximum it is round and spiky all the way around.
    func corona(_ c: P2, _ sunR: Double, _ e: CoverEvents.Eclipse, alpha: Double) {
        let B = glowBlend
        let col: RGB01 = (0.96, 0.97, 1.0)
        glow(c, sunR * 2.0, col, 0.5 * alpha, raw: true, B)
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
            streamer(c, sunR, ang, len, rng.range(0.35, 0.7), col, 0.3 * alpha)
        }
        if e.corona == 0 {
            for i in 0..<12 {
                let base = i < 6 ? -Double.pi / 2 : Double.pi / 2
                let ang = base + (Double(i % 6) - 2.5) * 0.14
                let dir = P2(cos(ang), sin(ang))
                line(c + dir * sunR, c + dir * (sunR * 1.55), max(0.4, sunR * 0.025), raw(col, 0.22 * alpha), raw(col, 0), B)
            }
        }
        ring(c, sunR * 1.04, max(0.6, sunR * 0.08), raw(col, 0.5 * alpha), B)
    }

    func streamer(_ c: P2, _ sunR: Double, _ ang: Double, _ len: Double, _ width: Double, _ col: RGB01, _ a: Double) {
        let ca = cos(ang), sa = sin(ang)
        func turned(_ p: P2) -> P2 { P2(c.x + p.x * ca - p.y * sa, c.y + p.x * sa + p.y * ca) }
        let mid = sunR * (0.9 + len) * 0.5
        let upper = quadCurve(P2(sunR * 0.9, -sunR * width), P2(mid, -sunR * width * 0.35), P2(sunR * len, 0))
        ribbon(upper.map(turned), upper.map { turned(P2($0.x, -$0.y)) }, glowBlend) { i in
            raw(col, a * (1 - CV.clamp((upper[i].x - sunR * 0.9) / (sunR * (len - 0.9)))))
        }
    }

    func prominences(_ c: P2, _ sunR: Double, _ e: CoverEvents.Eclipse, _ a: Double) {
        let B = glowBlend
        var rng = SeededRandom(seed: e.seed &+ 99)
        let n = e.corona == 2 ? 5 : 3
        let pink = raw(SkyInk.prominence, 0.85 * a)
        for _ in 0..<n {
            let ang = rng.range(0, CV.tau)
            let h = sunR * rng.range(0.06, 0.16)
            let ca = cos(ang), sa = sin(ang)
            func turned(_ x: Double, _ y: Double) -> P2 { P2(c.x + x * ca - y * sa, c.y + x * sa + y * ca) }
            stroke(quadCurve(turned(sunR * 1.03, -h * 0.6), turned(sunR + h * 2.2, 0), turned(sunR * 1.03, h * 0.6), steps: 10),
                   max(0.6, h * 0.5), B) { _ in pink }
        }
        // the chromosphere: a thin pink rim
        ring(c, sunR * 1.035, max(0.5, sunR * 0.03), raw(SkyInk.prominence, 0.3 * a), B)
    }

    /// Baily's beads and the diamond ring: the last sunlight shining through lunar valleys at the limb.
    func beads(_ c: P2, _ sunR: Double, _ moonC: P2, _ g: SolarGeometry, _ a: Double) {
        let B = glowBlend
        let c2 = g.moonR - 1
        let d0 = g.sep - c2
        guard d0 > -0.004, d0 < 0.07 else { return }
        let strength = a * (1 - CV.clamp(abs(d0 - 0.012) / 0.058))
        guard strength > 0.01 else { return }
        let vx = c.x - moonC.x, vy = c.y - moonC.y
        let base = (vx * vx + vy * vy).squareRoot() < 1e-6 ? Double.pi : atan2(vy, vx)
        let diamond = P2(c.x + cos(base) * sunR, c.y + sin(base) * sunR)
        glow(diamond, sunR * 0.9, (1, 1, 0.97), 0.8 * strength, raw: true, B)
        spikes(diamond, sunR * 1.4, raw((1, 1, 1), 0.5 * strength), max(0.5, sunR * 0.03), B)
        for i in -3...3 where i != 0 {
            let ang = base + Double(i) * 0.12
            glow(P2(c.x + cos(ang) * sunR, c.y + sin(ang) * sunR), sunR * 0.12, (1, 1, 0.95),
                 0.9 * strength * (1 - abs(Double(i)) * 0.2), raw: true, B)
        }
    }

    // MARK: Meteors

    /// Meteors from tonight's active showers, flying straight out of their real radiants, plus sporadic ones.
    /// Fast meteors (Leonids 71 km/s) are short, blue-green and may leave a glowing train; slow ones
    /// (Draconids 20 km/s) are long, lingering and golden.
    func meteors(t: Double, sky: SkyNow) {
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
        let B = glowBlend
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
                let b = peak * pow(sin(Double.pi * u), 0.6)
                line(pt(sx + dx * tailD, sy + dy * tailD), head, max(0.6, w * 0.0045), ink(col, 0), ink(col, b), B)
                glow(head, w * 0.012, col, 0.5 * b, raw: dark, B)
            }
            if hasTrain {
                // a persistent train: glowing oxygen left by a fast meteor, bent by the upper-air wind
                let tu = (age - duration * 0.5) / (trainLife + duration * 0.5)
                if tu > 0 && tu < 1 {
                    let wind = 0.012 * tu
                    let a0 = pt(sx - dy * wind, sy + dx * wind)
                    let a1 = pt(sx + dx * len - dy * wind * 1.6, sy + dy * len + dx * wind * 1.6)
                    let bend = pt(sx + dx * len * 0.5 - dy * wind * 2.4, sy + dy * len * 0.5 + dx * wind * 2.4)
                    let train = ink((0.6, 1.0, 0.75), 0.2 * peak * pow(1 - tu, 1.4))
                    stroke(quadCurve(a0, bend, a1), max(0.8, w * 0.006 * (1 + tu)), B) { _ in train }
                }
            }
        }
    }

    // MARK: The reading orbit

    /// Your place in the book as a planet's place in its real orbit: true eccentricity and orientation,
    /// and Kepler's second law, so equal amounts of reading sweep out equal areas.
    func orrery(t: Double, progress: Double) {
        guard d.body >= 0, d.body < Int(sky_body_count()), let ptr = sky_body_at(Int32(d.body)) else { return }
        let b = ptr.pointee
        let e = b.e
        let a = 0.085
        let varpi = b.varpi * Double.pi / 180
        let retro = b.retrograde != 0
        let cx = Double(d.orreryCenter.x), cy = Double(d.orreryCenter.y)
        let sunX = cx + a * e * cos(varpi), sunY = cy - a * e * sin(varpi)
        let minor = (1 - e * e).squareRoot()
        func orbitPoint(_ E: Double) -> P2 {
            let x = cos(E) - e
            var y = minor * sin(E)
            if retro { y = -y }
            let rx = x * cos(varpi) - y * sin(varpi)
            let ry = x * sin(varpi) + y * cos(varpi)
            return pt(sunX + rx * a, sunY - ry * a)
        }
        let bodyCol: RGB01 = (Double(b.r), Double(b.g), Double(b.b))
        let lineCol = raw(dark ? (0.85, 0.88, 1.0) : pal.ink01, dark ? 0.16 : 0.2)
        stroke((0..<72).map { orbitPoint(Double($0) / 72 * CV.tau) }, max(0.5, w * 0.0028), closed: true, .normal) { _ in lineCol }

        let B = glowBlend
        let sun = pt(sunX, sunY)
        let Ep = CoverPainter.eccentricAnomaly(CV.tau * min(progress, 0.999), e)
        if progress > 0.002 {
            let steps = max(2, Int(48 * progress) + 2)
            let arc = (0...steps).map { orbitPoint(Ep * Double($0) / Double(steps)) }
            let swept = ink(bodyCol, 0.08), travelled = ink(bodyCol, 0.55)
            for i in 0..<steps {
                scene.triangle(vertex(sun, swept), vertex(arc[i], swept), vertex(arc[i + 1], swept), B)
            }
            stroke(arc, max(0.7, w * 0.005), B) { _ in travelled }
        }
        glow(sun, w * 0.02, (1.0, 0.85, 0.5), 0.5, raw: dark, B)
        disc(sun, max(0.8, w * 0.0055), ink((1.0, 0.9, 0.6), 0.95), B)
        let pulse = 0.85 + 0.15 * sin(CV.tau * t / 5)
        let q = orbitPoint(Ep)
        glow(q, w * 0.022, bodyCol, 0.45 * pulse, raw: dark, B)
        disc(q, max(0.8, w * 0.006), ink(CV.mix(bodyCol, (1, 1, 1), 0.3), 0.95), B)
    }

    // MARK: The lens

    func lensShadow(_ L: Lens) {
        let rE = L.theta * w
        let s = L.strength
        let here = cp.skyAt(Double(L.center.y))
        let core = dark ? CV.mix(here, (0, 0, 0), 0.6) : CV.mix(here, pal.ink01, 0.05)
        radial(pt(L.center), rE * 1.6, rE * 1.6,
               stops: [(0, raw(core, 0.8 * s)), (0.45, raw(here, 0.55 * s)), (1, raw(here, 0))], .normal)
    }

    func lensRing(_ L: Lens) {
        let rE = L.theta * w
        let s = L.strength
        let col: RGB01 = dark ? (0.85, 0.9, 1.0) : pal.ink01
        ring(pt(L.center), rE, max(0.6, rE * 0.09), raw(col, 0.22 * s), glowBlend)
        ring(pt(L.center), rE, max(1.5, rE * 0.35), raw(col, 0.07 * s), glowBlend)
    }
}
