#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// Every cover in Folio is painted by the app, never taken from the book. The ethereal colours and
// mist come from the title; the sky over them is real:
//
//  • a real constellation from the HYG catalogue — true positions, magnitudes, B–V colours — whose
//    stars shift by their real distances (nearby Sirius moves, far-off Deneb barely does);
//  • the Milky Way from its real outline, Great Rift and Coalsack included, and the ecliptic glow;
//  • that constellation's famous deep-sky objects, drawn after their real structure;
//  • tonight's actual Moon phase, and real eclipses — on the day they happen, and as replays;
//  • tonight's planets wherever they really are;
//  • real meteor showers, active by date, streaking from their real radiants at their real speeds;
//  • great comets with physically correct ion and dust tails;
//  • aurora coloured by real emission lines and as strong as NOAA's live Kp index;
//  • historic supernovae and novae replayed where they appeared;
//  • a real orbit (true eccentricity, Kepler's second law) whose position is your reading progress;
//  • the constellation's figure, drawn one line per bookmark;
//  • gravitational lensing under the pointer, using the point-mass lens equation.

enum CoverClock { static let start = Date() }

/// Whether anyone can see the covers: Folio is the front app and one of its windows is showing.
/// Covers stop drawing when this is false.
final class CoverActivity: ObservableObject {
    static let shared = CoverActivity()
    @Published private(set) var awake = true

    private init() {
        let nc = NotificationCenter.default
        #if os(macOS)
        let names = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didChangeOcclusionStateNotification]
        #else
        let names = [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification]
        #endif
        for name in names {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        #if os(macOS)
        guard let app = NSApp else { return }
        let now = app.isActive && app.occlusionState.contains(.visible)
        #else
        let now = UIApplication.shared.applicationState == .active
        #endif
        if now != awake { awake = now }
    }
}

/// True for covers that are out of sight behind something else, such as the shelf while a book is held
/// up in front of it: they keep the picture they have and stop drawing.
private struct CoversRestingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var coversResting: Bool {
        get { self[CoversRestingKey.self] }
        set { self[CoversRestingKey.self] = newValue }
    }
}

/// Deterministic SplitMix64 — the same title always yields the same cover.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    init(text: String) {
        var h: UInt64 = 0xCBF29CE484222325          // FNV-1a
        for b in text.utf8 { h ^= UInt64(b); h = h &* 0x100000001B3 }
        state = h
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func pick(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

typealias CoverRGB = (Double, Double, Double)

struct CoverPalette {
    let top: CoverRGB
    let bottom: CoverRGB
    let glows: [CoverRGB]
    let ink: CoverRGB
    let dark: Bool          // dark palettes are night skies, light ones twilight

    static func rgb(_ c: CoverRGB, _ a: Double = 1) -> Color {
        Color(.sRGB, red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, opacity: max(0, min(1, a)))
    }

    var ink01: RGB01 { (ink.0 / 255, ink.1 / 255, ink.2 / 255) }
    var bottom01: RGB01 { (bottom.0 / 255, bottom.1 / 255, bottom.2 / 255) }

    static let all: [CoverPalette] = [
        // Dawn
        .init(top: (247, 226, 222), bottom: (214, 206, 235),
              glows: [(255, 168, 148), (200, 150, 240), (255, 214, 168), (160, 196, 250)], ink: (70, 58, 92), dark: false),
        // Sea mist
        .init(top: (214, 236, 238), bottom: (178, 206, 222),
              glows: [(120, 214, 210), (200, 238, 232), (150, 170, 238), (255, 255, 255)], ink: (36, 64, 84), dark: false),
        // Aurora
        .init(top: (18, 24, 58), bottom: (8, 10, 28),
              glows: [(90, 240, 200), (150, 110, 255), (60, 140, 255), (255, 140, 220)], ink: (240, 244, 255), dark: true),
        // Moonlight
        .init(top: (30, 38, 72), bottom: (12, 14, 34),
              glows: [(200, 215, 255), (255, 226, 170), (140, 160, 230), (255, 255, 255)], ink: (236, 238, 250), dark: true),
        // Bloom
        .init(top: (252, 234, 240), bottom: (236, 222, 246),
              glows: [(255, 150, 186), (196, 150, 255), (255, 204, 168), (255, 250, 250)], ink: (96, 52, 84), dark: false),
        // Dusk
        .init(top: (64, 36, 82), bottom: (24, 14, 40),
              glows: [(255, 160, 110), (255, 110, 160), (170, 110, 230), (255, 220, 160)], ink: (252, 236, 230), dark: true),
        // Lagoon
        .init(top: (12, 40, 56), bottom: (6, 18, 30),
              glows: [(80, 220, 230), (120, 255, 200), (60, 120, 220), (230, 255, 250)], ink: (230, 250, 250), dark: true),
        // Pearl
        .init(top: (242, 240, 236), bottom: (220, 222, 230),
              glows: [(250, 206, 222), (196, 222, 252), (238, 222, 186), (214, 198, 252)], ink: (64, 64, 82), dark: false),
    ]
}

/// One book's cover: palette, sky, layout and event schedule, all derived from title and author.
struct CoverDesign {
    /// The number a title draws to choose its sky; the shelf turns it into a sky nobody else has.
    static func draw(title: String, author: String) -> UInt64 {
        var rng = SeededRandom(text: title + "\u{1F}" + author)
        _ = rng.next()                  // the palette's draw comes first
        return rng.next()
    }

    struct Orb {
        var x, y, r, opacity: Double
        var color: CoverRGB
        var periodX, periodY, phaseX, phaseY, driftX, driftY: Double
        var breathPeriod, breathPhase, breath: Double
    }

    let key: String
    let palette: CoverPalette
    let field: SkyField
    var orbs: [Orb] = []

    var hasMoon = true
    var moonCenter = CGPoint(x: 0.5, y: 0.3)
    var moonD = 0.34
    var body = 0
    var orreryCenter = CGPoint(x: 0.86, y: 0.13)

    var eclipseCycle = 480.0, eclipsePhase = 0.0, eclipseStart = 0
    var cometCycle = 600.0, cometPhase = 0.0, cometStart = 0
    var flareCycle = 720.0, flarePhase = 0.0
    var dimCycle = 660.0, dimPhase = 0.0
    var meteorSeed: UInt64 = 0
    var driftTx = 40.0, driftTy = 53.0, driftPx = 0.0, driftPy = 0.0
    var grainSeed: UInt64 = 0
    var detailSeed: UInt64 = 0
    var flarePoint: CGPoint?
    var radiants: [CGPoint?] = []

    /// `sky` is the piece of sky the shelf gave this book (so that no two books share one);
    /// without it the title chooses.
    init(title: String, author: String, sky: Int? = nil) {
        let seed = title + "\u{1F}" + author
        var rng = SeededRandom(text: seed)
        palette = CoverPalette.all[rng.pick(CoverPalette.all.count)]
        let count = SkyCatalog.shared.count
        let chosen = Int(rng.next() % UInt64(max(1, count)))
        let index = sky.map { min(max(0, $0), count - 1) } ?? chosen
        key = seed + "\u{1F}\(index)"
        field = SkyCatalog.shared.field(index)

        // Ethereal mist
        let first = rng.pick(4)
        var placed: [(x: Double, y: Double, r: Double, a: Double, c: CoverRGB)] = []
        for i in 0..<5 {
            let x = rng.range(-0.1, 1.1), y = rng.range(-0.05, 1.25), r = rng.range(0.35, 0.7), a = rng.range(0.45, 0.85)
            placed.append((x, y, r, a, palette.glows[(first + i) % palette.glows.count]))
        }

        // The Moon goes where it hides the fewest bright stars
        hasMoon = rng.unit() < 0.7
        moonD = rng.range(0.30, 0.37)
        let spots = [CGPoint(x: 0.30, y: 0.30), CGPoint(x: 0.70, y: 0.30), CGPoint(x: 0.50, y: 0.24),
                     CGPoint(x: 0.28, y: 0.58), CGPoint(x: 0.72, y: 0.58), CGPoint(x: 0.50, y: 0.52)]
        var best = Double.infinity
        for s in spots {
            var mass = rng.range(0, 0.6)
            for st in field.stars where st.line || st.mag < 2.5 {
                let dx = st.p.x - s.x, dy = st.p.y - s.y
                if (dx * dx + dy * dy).squareRoot() < moonD * 0.8 { mass += max(0.3, 4.5 - st.mag) }
            }
            for d in field.dsos {
                let dx = d.p.x - s.x, dy = d.p.y - s.y
                if (dx * dx + dy * dy).squareRoot() < moonD * 0.7 + d.size * 0.3 { mass += 2.5 }
            }
            if mass < best { best = mass; moonCenter = s }
        }

        // The orrery sits in whichever top corner is clear of the Moon
        if hasMoon && moonCenter.x > 0.55 && moonCenter.y < 0.45 {
            orreryCenter = CGPoint(x: 0.15, y: 0.24)
        } else {
            orreryCenter = CGPoint(x: 0.86, y: 0.13)
        }
        body = rng.pick(Int(sky_body_count()))

        eclipseCycle = rng.range(360, 600); eclipsePhase = rng.range(0, eclipseCycle)
        eclipseStart = rng.pick(Int(sky_replay_count()))
        cometCycle = rng.range(360, 620); cometPhase = rng.range(0, cometCycle)
        cometStart = rng.pick(Int(sky_comet_count()))
        flareCycle = rng.range(300, 520); flarePhase = rng.range(0, flareCycle)
        dimCycle = rng.range(300, 480); dimPhase = rng.range(0, dimCycle)
        meteorSeed = rng.next()
        driftTx = rng.range(34, 52); driftTy = rng.range(41, 63)
        driftPx = rng.range(0, 2 * .pi); driftPy = rng.range(0, 2 * .pi)
        grainSeed = rng.next()
        detailSeed = rng.next()

        var m = SeededRandom(seed: grainSeed ^ 0x5EED_C0FE_E7E2_EA11)
        let tau = 2 * Double.pi
        for p in placed {
            orbs.append(Orb(x: p.x, y: p.y, r: p.r, opacity: p.a, color: p.c,
                            periodX: m.range(14, 26), periodY: m.range(16, 30), phaseX: m.range(0, tau), phaseY: m.range(0, tau),
                            driftX: m.range(0.04, 0.09), driftY: m.range(0.03, 0.07),
                            breathPeriod: m.range(9, 17), breathPhase: m.range(0, tau), breath: m.range(0.04, 0.09)))
        }

        if field.flare >= 0, let f = sky_flare_at(Int32(field.flare)) {
            flarePoint = field.project(ra: f.pointee.ra, dec: f.pointee.dec)
        }
        radiants = field.showers.map { i -> CGPoint? in
            let s = SkyShowerInfo(i)
            return field.project(ra: s.ra, dec: s.dec)
        }
    }
}

final class CoverDesignCache {
    static let shared = CoverDesignCache()
    private var designs: [String: CoverDesign] = [:]

    func design(title: String, author: String, sky: Int? = nil) -> CoverDesign {
        let key = title + "\u{1F}" + author + "\u{1F}\(sky ?? -1)"
        if let d = designs[key] { return d }
        let d = CoverDesign(title: title, author: author, sky: sky)
        designs[key] = d
        return d
    }
}

/// Pointer state for one cover. A class so that moving the pointer doesn't rebuild the view.
final class HoverBox {
    var point: CGPoint?          // cover units
    var enteredAt = -100.0
    var exitedAt = -100.0
    var movedAt = -100.0         // when the pointer last moved over the cover
    var inside = false
    var visits = 0

    func info(_ t: Double) -> HoverInfo? {
        let s = inside ? min(1, max(0, (t - enteredAt) / 0.45)) : max(0, 1 - (t - exitedAt) / 0.45)
        guard s > 0.001, let p = point else { return nil }
        return HoverInfo(point: p, strength: s, visits: visits)
    }
}

struct HoverInfo {
    let point: CGPoint
    let strength: Double
    let visits: Int
}

/// The never-changing part of a cover: sky colour, Milky Way, zodiacal glow, grain, label.
struct StaticSky: View, Equatable {
    let design: CoverDesign

    static func == (a: StaticSky, b: StaticSky) -> Bool { a.design.key == b.design.key }

    var body: some View {
        Canvas { ctx, size in design.drawStatic(&ctx, size: size) }
            .allowsHitTesting(false)
    }
}

/// The cover. Works at any size; everything is proportional to its width.
struct EtherealCover: View {
    let title: String
    let author: String
    var progress: Double = 0
    var bookmarks: Int = 0
    var animated = true

    @AppStorage(Keys.animateCovers) private var animateCovers = true
    @AppStorage(Keys.coverStyle) private var coverStyle = CoverStyle.sky.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coversResting) private var resting
    @ObservedObject private var activity = CoverActivity.shared
    @State private var hoverBox = HoverBox()
    @State private var hovering = false

    private let design: CoverDesign
    private let fixedStyle: CoverStyle?

    /// `style` fixes the kind of cover (the sky gallery always shows skies); otherwise it follows the setting.
    init(title: String, author: String, sky: Int? = nil, progress: Double = 0, bookmarks: Int = 0, animated: Bool = true,
         style: CoverStyle? = nil) {
        self.title = title
        self.author = author
        self.progress = progress
        self.bookmarks = bookmarks
        self.animated = animated
        self.design = CoverDesignCache.shared.design(title: title, author: author, sky: sky)
        self.fixedStyle = style
    }

    /// Landscapes are painted by the GPU renderer, which only the Mac has; elsewhere covers are skies.
    private var landscape: LandscapeDesign? {
        #if os(macOS)
        let style = fixedStyle ?? CoverStyle(rawValue: coverStyle) ?? .sky
        guard style == .landscape, CoverRenderer.shared?.paintsLandscapes == true else { return nil }
        return LandscapeCache.shared.design(title: title, author: author)
        #else
        return nil
        #endif
    }

    var body: some View {
        let d = design
        let land = landscape
        let p = land?.palette ?? d.palette
        let moving = animated && animateCovers && !reduceMotion
        let progress = self.progress
        let bookmarks = self.bookmarks
        let box = hoverBox
        let awake = activity.awake && !resting
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                if let land {
                    Rectangle().fill(land.backdrop)                 // until the GPU's first picture arrives
                } else {
                    StaticSky(design: d).equatable()
                }

                #if os(macOS)
                if CoverRenderer.shared != nil {
                    CoverSky(design: d, landscape: land, progress: progress, bookmarks: bookmarks, moving: moving,
                             awake: awake, hovering: hovering, hoverBox: box)
                        .allowsHitTesting(false)
                }
                #else
                CoverStars(design: d, moving: moving, awake: awake).allowsHitTesting(false)
                #endif

                if land == nil {                                    // a landscape brings its own vignette
                    RadialGradient(colors: [CoverPalette.rgb(p.bottom, 0), CoverPalette.rgb(p.bottom, p.dark ? 0.55 : 0.30)],
                                   center: UnitPoint(x: 0.5, y: 0.42), startRadius: w * 0.35, endRadius: w * 1.05)
                        .allowsHitTesting(false)
                }

                // A soft veil so the title reads over the sky
                LinearGradient(stops: [
                    .init(color: p.dark ? CoverPalette.rgb(p.bottom, 0) : Color.white.opacity(0), location: 0.48),
                    .init(color: p.dark ? CoverPalette.rgb(p.bottom, 0.55) : Color.white.opacity(0.40), location: 0.8),
                    .init(color: p.dark ? CoverPalette.rgb(p.bottom, 0.40) : Color.white.opacity(0.24), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)

                if w >= 50 {
                    VStack(spacing: w * 0.035) {
                        Rectangle().fill(CoverPalette.rgb(p.ink, 0.45)).frame(width: w * 0.12, height: max(0.5, w * 0.004))
                        Text(title)
                            .font(.system(size: w * 0.105, weight: .light, design: .serif))
                            .tracking(w * 0.002)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(CoverPalette.rgb(p.ink))
                        if !author.isEmpty && w >= 90 {
                            Text(author.uppercased())
                                .font(.system(size: w * 0.042, weight: .regular, design: .serif))
                                .tracking(w * 0.012)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.6)
                                .foregroundStyle(CoverPalette.rgb(p.ink, 0.72))
                        }
                    }
                    .shadow(color: Color.white.opacity(p.dark ? 0.45 : 0.85), radius: w * 0.03)
                    .padding(.horizontal, w * 0.12)
                    .frame(width: w, height: h * 0.42)
                    .position(x: w * 0.5, y: h * 0.72)
                    .allowsHitTesting(false)
                }

                // The constellation this cover shows, or the name of the country
                if w >= 100 {
                    Text((land?.name ?? d.field.name).uppercased())
                        .font(.system(size: max(6.5, w * 0.04), weight: .medium, design: .serif))
                        .tracking(w * 0.012)
                        .lineLimit(1)
                        .foregroundStyle(CoverPalette.rgb(p.ink, p.dark ? 0.5 : 0.45))
                        .padding(.leading, w * 0.07)
                        .padding(.top, w * 0.06)
                        .frame(width: w, height: h, alignment: .topLeading)
                        .opacity(hovering ? 0 : 1)
                        .animation(.easeOut(duration: 0.3), value: hovering)
                        .allowsHitTesting(false)
                }

                // What is under the pointer, and what the real sky is doing tonight
                if hovering && w >= 110 {
                    CoverCaption(design: d, landscape: land, box: box, moving: moving, progress: progress, awake: awake)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                let t = Date().timeIntervalSince(CoverClock.start)
                switch phase {
                case .active(let location):
                    if !box.inside {
                        box.inside = true
                        box.enteredAt = t
                        box.visits += 1
                        withAnimation(.easeOut(duration: 0.45)) { hovering = true }
                    }
                    let point = CGPoint(x: location.x / max(1, w), y: location.y / max(1, w))
                    if point != box.point {
                        box.point = point
                        box.movedAt = t
                        #if os(macOS)
                        CoverRenderer.shared?.wake()        // the lens follows the pointer
                        #endif
                    }
                case .ended:
                    box.inside = false
                    box.exitedAt = t
                    withAnimation(.easeOut(duration: 0.45)) { hovering = false }
                }
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(author.isEmpty ? title : "\(title), by \(author)")
    }
}

/// What is under the pointer, and what the real sky is doing tonight. The words are worked out four
/// times a second, and the card is set again only when they change; the fade in and out is left to the
/// compositor. (A TimelineView here kept the whole window redrawing at every frame the covers drew.)
struct CoverCaption: View {
    let design: CoverDesign
    let landscape: LandscapeDesign?
    let box: HoverBox
    let moving: Bool
    let progress: Double
    let awake: Bool
    @State private var lines: (String, String, String)?

    /// What the words depend on besides the pointer and the clock.
    private struct Key: Equatable {
        let width: CGFloat
        let height: CGFloat
        let awake: Bool
        let landscape: String?
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                Color.clear
                if let shown = lines ?? words(size) {
                    CaptionCard(lines: shown, palette: landscape?.palette ?? design.palette, width: size.width)
                        .equatable()
                }
            }
            .task(id: Key(width: size.width, height: size.height, awake: awake, landscape: landscape?.name)) {
                repeat {
                    if let next = words(size), lines.map({ $0 != next }) ?? true { lines = next }
                    guard awake else { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                } while !Task.isCancelled
            }
        }
    }

    private func words(_ size: CGSize) -> (String, String, String)? {
        guard let point = box.point else { return nil }
        if let landscape { return landscape.captionLines(at: point, visits: box.visits, sky: SkyNow.current) }
        let now = Date().timeIntervalSince(CoverClock.start)
        return design.captionLines(size: size, at: point, visits: box.visits, t: moving ? now : 0,
                                   sky: SkyNow.current, kp: SpaceWeather.shared.kp, progress: progress)
    }
}

/// The caption's words on a soft scrim along the top of the cover.
struct CaptionCard: View, Equatable {
    let lines: (String, String, String)
    let palette: CoverPalette
    let width: CGFloat

    /// The same words at the same size are not set again.
    static func == (a: CaptionCard, b: CaptionCard) -> Bool {
        a.lines == b.lines && a.width == b.width && a.palette.dark == b.palette.dark
            && a.palette.ink == b.palette.ink && a.palette.bottom == b.palette.bottom
    }

    var body: some View {
        let w = Double(width)
        let pad = w * 0.07
        let gap = w * 0.018
        let fs1 = max(8.5, w * 0.066), fs2 = max(7.5, w * 0.05)
        let ink: Color = palette.dark ? .white : CoverPalette.rgb(palette.ink)
        let base = palette.dark ? CoverPalette.rgb(palette.bottom, 0.86) : Color.white.opacity(0.84)
        let clear = palette.dark ? CoverPalette.rgb(palette.bottom, 0) : Color.white.opacity(0)
        VStack(alignment: .leading, spacing: gap) {
            Text(lines.0)
                .font(.system(size: fs1, weight: .semibold, design: .serif))
                .foregroundStyle(ink.opacity(0.96))
            Text(lines.1)
                .font(.system(size: fs2, weight: .regular, design: .serif))
                .foregroundStyle(ink.opacity(0.86))
            Text(lines.2)
                .font(.system(size: fs2 * 0.95, weight: .regular, design: .serif).italic())
                .foregroundStyle(ink.opacity(0.66))
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: max(1, w - 2 * pad), alignment: .leading)
        .padding(.top, pad)
        .padding(.bottom, pad * 1.6)
        .frame(width: w)
        .background(LinearGradient(stops: [.init(color: base, location: 0), .init(color: base, location: 0.72),
                                           .init(color: clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
