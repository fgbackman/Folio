import Foundation
import SwiftUI

// Swift view of the C sky engine (core/sky.c, core/skydata.c): real constellations with their
// stars, figures, deep-sky objects and Milky Way, plus "what the sky is doing now" — tonight's
// Moon and planets, active meteor showers, eclipses and live geomagnetic activity.

typealias RGB01 = (Double, Double, Double)

func skyColor(_ c: RGB01, _ a: Double) -> Color {
    Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: max(0, min(1, a)))
}

struct SkyStar {
    let p: CGPoint            // cover units: 1 wide, 1.5 tall
    let mag: Double
    let rgb: RGB01
    let parallax: Double      // 0…1, nearer stars shift more
    let ly: Double
    let name: String?
    let desc: String?
    let line: Bool
    let variable: Int
    let twinklePeriod: Double
    let twinklePhase: Double
}

struct SkyDSO {
    let name: String
    let detail: String
    let kind: Int32
    let variant: Int
    let p: CGPoint
    let size: Double          // major axis, cover units
    let ratio: Double
    let angle: Double         // radians, screen
    let period: Double
}

struct SkyField {
    let index: Int
    let abbr: String
    let name: String
    let stars: [SkyStar]
    let segs: [(Int, Int)]
    let dsos: [SkyDSO]
    let milkyWay: [[[[CGPoint]]]]   // level → polygon → ring → points
    let ecliptic: [[CGPoint]]
    let showers: [Int]
    let aurora: Int
    let flare: Int
    let pole: Int
    let facts: [String]
    let lens: String
    let warmMilkyWay: Bool
    let ptr: UnsafePointer<sky_constellation>

    func project(ra: Double, dec: Double) -> CGPoint? {
        var x = 0.0, y = 0.0
        guard sky_project(ptr, ra, dec, &x, &y) != 0 else { return nil }
        return CGPoint(x: x, y: y)
    }
}

final class SkyCatalog {
    static let shared = SkyCatalog()
    private var cache: [Int: SkyField] = [:]
    let count: Int = Int(sky_constellation_count())
    /// The constellations Folio began with. Their covers are left exactly as they were.
    static let firstSkies = 42

    func field(_ i: Int) -> SkyField {
        if let f = cache[i] { return f }
        let f = build(i)
        cache[i] = f
        return f
    }

    private func str(_ p: UnsafePointer<CChar>?) -> String {
        guard let p else { return "" }
        return String(cString: p)
    }

    private func build(_ i: Int) -> SkyField {
        let ptr = sky_constellation_at(Int32(i))!
        let c = ptr.pointee
        var rng = SeededRandom(seed: UInt64(i) &* 0x9E3779B97F4A7C15 &+ 77)

        // A field zoomed in on a cluster or a small asterism holds only faint stars. They are drawn as if
        // seen through a telescope: brightened together until the fifth brightest is an easy naked-eye star.
        var lift = 0.0
        if i >= SkyCatalog.firstSkies, c.nstars > 5 {
            let mags = (0..<Int(c.nstars)).map { Double(c.stars[$0].mag) }.sorted()
            lift = min(4.5, max(0, mags[4] - 2.6))
        }

        var stars: [SkyStar] = []
        stars.reserveCapacity(Int(c.nstars))
        for k in 0..<Int(c.nstars) {
            let s = c.stars[k]
            var r: Float = 1, g: Float = 1, b: Float = 1
            sky_bv_rgb(s.bv, &r, &g, &b)
            let ly = Double(s.dist)
            let parallax = ly > 0 ? min(1.0, max(0.05, (10.0 / ly).squareRoot())) : 0.08
            stars.append(SkyStar(
                p: CGPoint(x: Double(s.x), y: Double(s.y)), mag: Double(s.mag) - lift,
                rgb: (Double(r), Double(g), Double(b)), parallax: parallax, ly: ly,
                name: s.name >= 0 ? str(sky_name(Int32(s.name))) : nil,
                desc: s.desc >= 0 ? str(sky_name(Int32(s.desc))) : nil,
                line: s.line != 0, variable: Int(s.variable),
                twinklePeriod: rng.range(1.4, 3.6), twinklePhase: rng.range(0, 2 * .pi)))
        }

        var segs: [(Int, Int)] = []
        for k in 0..<Int(c.nsegs) { segs.append((Int(c.segs[k].a), Int(c.segs[k].b))) }

        var dsos: [SkyDSO] = []
        for k in 0..<Int(c.ndsos) {
            let d = c.dsos[k]
            dsos.append(SkyDSO(name: str(d.name), detail: str(d.detail), kind: Int32(d.kind), variant: Int(d.variant),
                               p: CGPoint(x: Double(d.x), y: Double(d.y)), size: Double(d.size),
                               ratio: Double(d.ratio), angle: Double(d.angle), period: Double(d.period)))
        }

        var mw: [[[[CGPoint]]]] = Array(repeating: [], count: 5)
        var polyIndex: [[Int: Int]] = Array(repeating: [:], count: 5)
        for k in 0..<Int(c.nrings) {
            let ring = c.rings[k]
            let level = min(4, Int(ring.level))
            var pts: [CGPoint] = []
            pts.reserveCapacity(Int(ring.count))
            for j in 0..<Int(ring.count) {
                let o = 2 * (Int(ring.start) + j)
                pts.append(CGPoint(x: Double(c.mw[o]), y: Double(c.mw[o + 1])))
            }
            let poly = Int(ring.poly)
            if let slot = polyIndex[level][poly] {
                mw[level][slot].append(pts)
            } else {
                polyIndex[level][poly] = mw[level].count
                mw[level].append([pts])
            }
        }

        var ecl: [[CGPoint]] = []
        var run: [CGPoint] = []
        for k in 0..<Int(c.necl) {
            let x = c.ecl[2 * k], y = c.ecl[2 * k + 1]
            if x.isNaN {
                if run.count > 1 { ecl.append(run) }
                run = []
            } else {
                run.append(CGPoint(x: Double(x), y: Double(y)))
            }
        }
        if run.count > 1 { ecl.append(run) }

        let sh = c.shower
        let showers = [Int(sh.0), Int(sh.1), Int(sh.2)].filter { $0 >= 0 }
        let abbr = str(c.abbr)
        return SkyField(index: i, abbr: abbr, name: str(c.name), stars: stars, segs: segs, dsos: dsos,
                        milkyWay: mw, ecliptic: ecl, showers: showers, aurora: Int(c.aurora),
                        flare: Int(c.flare), pole: Int(c.pole),
                        facts: str(c.facts).split(separator: "\n").map(String.init),
                        lens: str(c.lens),
                        warmMilkyWay: ["Sgr", "Sco", "Oph", "Ser", "Sct"].contains(abbr),
                        ptr: ptr)
    }
}

// MARK: - The sky right now

struct SkyPlanet {
    let index: Int
    let name: String
    let ra: Double
    let dec: Double
    let mag: Double
    let rgb: RGB01
    let visible: Bool         // far enough from the Sun to be seen
}

struct SkyNow {
    let date: Date
    let jd: Double
    let moonIllum: Double
    let moonElongation: Double
    let moonRA: Double
    let moonDec: Double
    let nextNew: Date
    let nextFull: Date
    let sunRA: Double
    let sunDec: Double
    let planets: [SkyPlanet]
    let showerZHR: [Double]
    let eclipseToday: (kind: Int, title: String)?

    var waxing: Bool { moonElongation < 180 }

    var moonPhaseName: String {
        let e = moonElongation
        switch e {
        case ..<6, 354...: return "New Moon"
        case ..<84: return "Waxing crescent"
        case ..<96: return "First quarter"
        case ..<174: return "Waxing gibbous"
        case ..<186: return "Full Moon"
        case ..<264: return "Waning gibbous"
        case ..<276: return "Last quarter"
        default: return "Waning crescent"
        }
    }

    private static var cached: SkyNow?

    static var current: SkyNow {
        if let c = cached, abs(c.date.timeIntervalSinceNow) < 120 { return c }
        let n = compute(Date())
        cached = n
        return n
    }

    static func compute(_ date: Date) -> SkyNow {
        let jd = sky_jd(date.timeIntervalSince1970)
        var mra = 0.0, mdec = 0.0, illum = 0.0, elong = 0.0
        sky_moon(jd, &mra, &mdec, &illum, &elong)
        var sra = 0.0, sdec = 0.0, slon = 0.0
        sky_sun(jd, &sra, &sdec, &slon)
        func dateFrom(_ j: Double) -> Date { Date(timeIntervalSince1970: (j - 2440587.5) * 86400) }
        var planets: [SkyPlanet] = []
        for p in 0..<7 {
            var ra = 0.0, dec = 0.0, mag = 0.0
            sky_planet(Int32(p), jd, &ra, &dec, &mag)
            var r: Float = 1, g: Float = 1, b: Float = 1
            sky_planet_rgb(Int32(p), &r, &g, &b)
            let sep = sky_separation(ra, dec, sra, sdec)
            planets.append(SkyPlanet(index: p, name: String(cString: sky_planet_name(Int32(p))), ra: ra, dec: dec,
                                     mag: mag, rgb: (Double(r), Double(g), Double(b)),
                                     visible: sep > 18 && mag < 6.2))
        }
        var zhr: [Double] = []
        for s in 0..<Int(sky_shower_count()) {
            zhr.append(Double(sky_shower_zhr(sky_shower_at(Int32(s)), jd)))
        }
        var today: (kind: Int, title: String)?
        if let e = sky_eclipse_on(jd) {
            today = (Int(e.pointee.kind), String(cString: e.pointee.title))
        }
        return SkyNow(date: date, jd: jd, moonIllum: illum, moonElongation: elong, moonRA: mra, moonDec: mdec,
                      nextNew: dateFrom(sky_moon_next(jd, 0)), nextFull: dateFrom(sky_moon_next(jd, 180)),
                      sunRA: sra, sunDec: sdec, planets: planets, showerZHR: zhr, eclipseToday: today)
    }
}

struct SkyShowerInfo {
    let name: String
    let parent: String
    let ra: Double
    let dec: Double
    let speed: Double
    let peak: String

    init(_ i: Int) {
        let s = sky_shower_at(Int32(i))!.pointee
        name = String(cString: s.name)
        parent = String(cString: s.parent)
        ra = s.ra
        dec = s.dec
        speed = Double(s.speed)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        peak = "\(s.dp) \(months[max(0, min(11, Int(s.mp) - 1))])"
    }
}

// MARK: - Live space weather (NOAA planetary K-index → aurora strength)

final class SpaceWeather {
    static let shared = SpaceWeather()
    static let defaultsKey = "spaceWeatherKp"
    static let url = URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json")!

    private(set) var kp: Double = UserDefaults.standard.object(forKey: SpaceWeather.defaultsKey) as? Double ?? 2.0
    private(set) var updated: Date? = UserDefaults.standard.object(forKey: SpaceWeather.defaultsKey + "Date") as? Date
    private var timer: Timer?

    var enabled: Bool { UserDefaults.standard.object(forKey: Keys.liveSpaceWeather) as? Bool ?? true }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard enabled else { return }
        var request = URLRequest(url: SpaceWeather.url)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let value = SpaceWeather.parse(data) else { return }
            DispatchQueue.main.async {
                SpaceWeather.shared.kp = value
                SpaceWeather.shared.updated = Date()
                UserDefaults.standard.set(value, forKey: SpaceWeather.defaultsKey)
                UserDefaults.standard.set(Date(), forKey: SpaceWeather.defaultsKey + "Date")
            }
        }.resume()
    }

    /// Accepts both NOAA formats: an array of objects with "Kp", or an array of rows with a header.
    static func parse(_ data: Data) -> Double? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var last: Double?
        for item in json {
            if let obj = item as? [String: Any] {
                if let v = obj["Kp"] as? Double { last = v }
                else if let v = obj["Kp"] as? NSNumber { last = v.doubleValue }
                else if let s = obj["Kp"] as? String, let v = Double(s) { last = v }
                else if let v = obj["kp_index"] as? Double { last = v }
            } else if let row = item as? [Any], row.count > 1 {
                if let s = row[1] as? String, let v = Double(s) { last = v }
                else if let v = row[1] as? Double { last = v }
            }
        }
        return last
    }
}
