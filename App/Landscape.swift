import SwiftUI

// The second kind of cover: an ethereal landscape, moving slowly — ridges drifting past at their own
// depths, mist wandering along the valleys, water holding the sky, birds, snow or fireflies. Each book
// draws its own from its title and author, like its sky: one of eight kinds of country (ranges, a lake
// under mountains, dunes, pine valleys, a sea of cloud, a coast, rolling downs, snow peaks) in one of
// fourteen moods of light. The Moon in the night scenes is tonight's, at its real phase.
//
// The GPU paints every pixel (CoverShaders, landscape_fragment); this file only decides what to paint.

/// Which covers the shelf shows.
enum CoverStyle: String, CaseIterable, Identifiable {
    case sky, landscape
    var id: String { rawValue }
    var name: String { self == .sky ? "Night Sky" : "Landscape" }
}

struct LandscapeDesign {
    /// The light: sky, air, land and water colours, and what is in the sky.
    struct Mood {
        let name: String
        let zenith, upper, horizon, sun, haze, mist, far, near, cloudLit, cloudShade, water, snow, particle, ink: String
        var glow = 0.5
        var dark = true                 // light lettering on it
        var moon = false                // a night scene, lit by the Moon
        var stars = 0.0
        var aurora = 0.0
        var rays = 0.0
        let words: [String]             // for its name
    }

    /// The country: its ridges from far to near (0 mountains, 1 hills, 2 dunes, 3 pines, 4 cloud,
    /// 5 cliffs, 6 woods) and the moods it is seen in.
    struct Country {
        let name: String
        let styles: [Int]
        var water = false
        var low = false                 // a low horizon: open water to the far shore
        var snow = false
        let moods: [String]
        let nouns: [String]
    }

    static let moods: [String: Mood] = [
        "rose dawn": Mood(name: "rose dawn", zenith: "9F8FCB", upper: "DDAFCA", horizon: "FFD6BA", sun: "FFF1DC", haze: "E6BCCB",
                          mist: "F6DCE2", far: "BF9CC0", near: "4E3D69", cloudLit: "FFE6E0", cloudShade: "C9A3C2", water: "8D7FA6",
                          snow: "FFF4F2", particle: "4A3B5E", ink: "FFF6F4", glow: 0.55, words: ["Rose", "Blush", "Dawn"]),
        "blue hour": Mood(name: "blue hour", zenith: "142445", upper: "2F4C7E", horizon: "8FAAD0", sun: "F4F2EA", haze: "6E8DB8",
                          mist: "A9BEDD", far: "5976A6", near: "0F1A33", cloudLit: "B9C9E3", cloudShade: "4B628E", water: "1C2C4F",
                          snow: "E6EEFA", particle: "E8F0FF", ink: "EEF3FF", glow: 0.35, moon: true, stars: 0.55,
                          words: ["Blue", "Indigo", "Evening"]),
        "golden haze": Mood(name: "golden haze", zenith: "EDC29C", upper: "F8DBB0", horizon: "FFF0CF", sun: "FFF6E0", haze: "F0C892",
                            mist: "FBE6C3", far: "D8A274", near: "5E3A2B", cloudLit: "FFF0D6", cloudShade: "D9A27A", water: "A87A55",
                            snow: "FFF6EA", particle: "4E3022", ink: "FFF7EC", glow: 0.7, rays: 0.6, words: ["Golden", "Amber", "Honey"]),
        "jade mist": Mood(name: "jade mist", zenith: "CFDDD7", upper: "E1EAE6", horizon: "F2F6F1", sun: "FFFDF5", haze: "D8E3DE",
                          mist: "EEF3F0", far: "9DB5AC", near: "223B35", cloudLit: "F7FAF8", cloudShade: "C3D2CC", water: "8FA9A1",
                          snow: "FFFFFF", particle: "2D3D39", ink: "22332F", glow: 0.25, dark: false, words: ["Jade", "Celadon", "Quiet"]),
        "twilight lilac": Mood(name: "twilight lilac", zenith: "4C3A78", upper: "9578BE", horizon: "F2BFD2", sun: "FFE0EA", haze: "B897CC",
                               mist: "E2CBE6", far: "8C70AE", near: "2E2148", cloudLit: "F8D3E3", cloudShade: "7C62A3", water: "3F2F63",
                               snow: "FBEFFF", particle: "FFE9A8", ink: "FFF2F8", glow: 0.5, words: ["Lilac", "Violet", "Twilight"]),
        "arctic night": Mood(name: "arctic night", zenith: "040A1A", upper: "0B1A35", horizon: "1C3A57", sun: "EEF2F7", haze: "1E3A55",
                             mist: "34577A", far: "23405E", near: "070F1C", cloudLit: "3A5A7D", cloudShade: "142A44", water: "0A1A30",
                             snow: "DCE8F5", particle: "EAF2FF", ink: "E8F1FF", glow: 0.25, moon: true, stars: 1.0, aurora: 1.0,
                             words: ["Northern", "Polar", "Starlit"]),
        "sea glass": Mood(name: "sea glass", zenith: "9FD3DC", upper: "C8EBEC", horizon: "EEFAF5", sun: "FFFFFF", haze: "D2EEEA",
                          mist: "EEF9F6", far: "94C4C0", near: "3F7E7F", cloudLit: "FFFFFF", cloudShade: "B7DCDA", water: "5FA3A6",
                          snow: "FFFFFF", particle: "2F5658", ink: "1F4446", glow: 0.45, dark: false, words: ["Glass", "Seafoam", "Bright"]),
        "ember dusk": Mood(name: "ember dusk", zenith: "26183A", upper: "6E3657", horizon: "EE8A5E", sun: "FFD49C", haze: "B05A65",
                           mist: "D88A84", far: "84465C", near: "1A1023", cloudLit: "FFC09A", cloudShade: "6A3550", water: "3A1C30",
                           snow: "FFE6D6", particle: "160C1C", ink: "FFEFE4", glow: 0.8, rays: 0.4, words: ["Ember", "Copper", "Smouldering"]),
        "pearl morning": Mood(name: "pearl morning", zenith: "CFC6E6", upper: "E8D6E6", horizon: "FFE9DC", sun: "FFF8EE", haze: "E6D6E0",
                              mist: "F5ECEE", far: "B7A6C2", near: "5E5274", cloudLit: "FFF8F4", cloudShade: "CBBFD3", water: "B3A9BF",
                              snow: "FFFFFF", particle: "6D6378", ink: "4B4256", glow: 0.4, dark: false, words: ["Pearl", "Morning", "Silver"]),
        "moonlit silver": Mood(name: "moonlit silver", zenith: "0C1222", upper: "26324D", horizon: "66759A", sun: "F2F2EC", haze: "55648A",
                               mist: "8592B3", far: "404D6C", near: "0A0E19", cloudLit: "A7B3CF", cloudShade: "303C5A", water: "121A2E",
                               snow: "E8ECF5", particle: "D6E6FF", ink: "EEF1FA", glow: 0.45, moon: true, stars: 0.7,
                               words: ["Moonlit", "Silver", "Midnight"]),
        "peach dunes": Mood(name: "peach dunes", zenith: "DFAE9C", upper: "F2C8B0", horizon: "FFE4CC", sun: "FFF4E4", haze: "F0C4A6",
                            mist: "FADDC6", far: "E2A587", near: "A55A40", cloudLit: "FFEADB", cloudShade: "D9A08A", water: "C98E73",
                            snow: "FFF4EA", particle: "6B3426", ink: "FFF5EE", glow: 0.6, words: ["Peach", "Apricot", "Warm"]),
        "forest fog": Mood(name: "forest fog", zenith: "8CA3A6", upper: "B5C7C4", horizon: "DCE6E0", sun: "F7FAF5", haze: "B1C3BE",
                           mist: "DFE9E4", far: "86A09A", near: "1C302C", cloudLit: "EEF4F1", cloudShade: "A3B8B3", water: "4E6B66",
                           snow: "FFFFFF", particle: "22332F", ink: "1E2E2A", glow: 0.3, dark: false, rays: 0.5,
                           words: ["Misty", "Grey", "Hushed"]),
        "sakura": Mood(name: "sakura", zenith: "EDBDD2", upper: "F7D6E2", horizon: "FFF0EA", sun: "FFF8F2", haze: "F0CCDA",
                       mist: "FBE9F0", far: "D9A3BC", near: "7A4462", cloudLit: "FFFFFF", cloudShade: "E9C2D1", water: "C99AB0",
                       snow: "FFFFFF", particle: "FFB8D2", ink: "5C3549", glow: 0.4, dark: false, words: ["Blossom", "Petal", "Spring"]),
        "northern dawn": Mood(name: "northern dawn", zenith: "6E8FB5", upper: "B7C6DD", horizon: "FAD6C8", sun: "FFF0E6", haze: "C9CFE0",
                              mist: "EEF0F6", far: "9BA9C6", near: "2B3956", cloudLit: "FFF2EE", cloudShade: "A7B4CF", water: "5B6E92",
                              snow: "FFFFFF", particle: "2B3956", ink: "F6F8FF", glow: 0.45, words: ["Frost", "Glacier", "Clear"]),
    ]

    static let scenes: [Country] = [
        Country(name: "range", styles: [0, 0, 0, 1, 3],
              moods: ["rose dawn", "blue hour", "golden haze", "jade mist", "twilight lilac", "ember dusk", "pearl morning",
                      "moonlit silver", "northern dawn", "forest fog"], nouns: ["Range", "Ridges", "Mountains"]),
        Country(name: "lake", styles: [0, 0, 1, 3], water: true,
              moods: ["rose dawn", "blue hour", "golden haze", "jade mist", "twilight lilac", "ember dusk", "pearl morning",
                      "moonlit silver", "northern dawn", "sea glass"], nouns: ["Lake", "Mere", "Water"]),
        Country(name: "dunes", styles: [2, 2, 2, 2, 2],
              moods: ["peach dunes", "golden haze", "ember dusk", "rose dawn", "moonlit silver", "pearl morning"],
              nouns: ["Dunes", "Sands", "Desert"]),
        Country(name: "pines", styles: [1, 1, 3, 3, 3],
              moods: ["forest fog", "jade mist", "blue hour", "moonlit silver", "golden haze", "twilight lilac", "arctic night"],
              nouns: ["Pines", "Forest", "Woods"]),
        Country(name: "cloudsea", styles: [0, 0, 4, 4],
              moods: ["rose dawn", "golden haze", "pearl morning", "ember dusk", "twilight lilac", "moonlit silver", "northern dawn"],
              nouns: ["Cloud Sea", "Summits", "Heights"]),
        Country(name: "coast", styles: [5, 5, 5], water: true, low: true,
              moods: ["sea glass", "pearl morning", "golden haze", "ember dusk", "blue hour", "rose dawn", "moonlit silver"],
              nouns: ["Coast", "Headlands", "Shore"]),
        Country(name: "highlands", styles: [1, 1, 6, 6],
              moods: ["jade mist", "forest fog", "pearl morning", "rose dawn", "golden haze", "sakura"],
              nouns: ["Downs", "Hills", "Vale"]),
        Country(name: "peaks", styles: [0, 0, 0, 0], snow: true,
              moods: ["arctic night", "northern dawn", "blue hour", "moonlit silver", "pearl morning"],
              nouns: ["Peaks", "Spires", "Glaciers"]),
    ]

    static let units = 1.5              // the cover is 1 unit wide and 1.5 tall

    let scene: Country
    let mood: Mood
    let name: String                    // "Amber Dunes", shown where a sky cover names its constellation
    let horizonY: Double
    let waterY: Double                  // 0 when there is no water
    let sun: CGPoint                    // cover units
    let sunSize: Double
    let layers: [SIMD4<Float>]          // base, height, frequency, style; far to near
    let timeOffset: Double              // so that no two covers move in step
    let particles: Int                  // 0 none, 1 birds, 2 snow, 3 petals, 4 fireflies
    let clouds: Double
    /// Everything the shader needs that never changes; the renderer fills in the pointer, the time and
    /// tonight's Moon (slots 1, 22 and 23) at each frame.
    let params: [SIMD4<Float>]

    init(title: String, author: String) {
        var rng = SeededRandom(text: title + "\u{1F}" + author + "\u{1F}land")
        let sc = LandscapeDesign.scenes[rng.pick(LandscapeDesign.scenes.count)]
        let m = LandscapeDesign.moods[sc.moods[rng.pick(sc.moods.count)]]!
        scene = sc
        mood = m
        let units = LandscapeDesign.units
        let night = m.moon
        let rays = m.rays * rng.range(0.6, 1.2)
        let rim = rng.range(0.25, 0.6) * (night ? 0.5 : 1.0)

        let water = sc.water || (sc.name == "range" && rng.unit() < 0.3)
        let horizon = sc.low ? rng.range(0.78, 0.86) : rng.range(0.62, 0.76)
        var waterLine = 0.0
        if water { waterLine = sc.low ? horizon + rng.range(0.02, 0.05) : rng.range(0.9, 1.02) }
        horizonY = horizon
        waterY = waterLine

        let sx = rng.range(0.22, 0.78)
        var sy: Double, size: Double
        if night {
            sy = rng.range(0.22, 0.42)
            size = rng.range(0.045, 0.065)
        } else {
            let lowSun = rng.unit() < 0.65
            sy = horizon * (lowSun ? rng.range(0.78, 0.98) : rng.range(0.3, 0.55))
            size = lowSun ? rng.range(0.05, 0.085) : rng.range(0.035, 0.05)
            if ["jade mist", "forest fog", "pearl morning"].contains(m.name) { size *= 0.85 }
        }
        sun = CGPoint(x: sx, y: sy)
        sunSize = size
        let glow = m.glow * rng.range(0.8, 1.2)
        let hasClouds = rng.unit() < 0.7
        let clouds = hasClouds ? rng.range(0.0, 0.55) : 0.0
        self.clouds = clouds
        let cloudY = horizon * rng.range(0.25, 0.6)
        let mist = sc.name == "dunes" ? rng.range(0.25, 0.45) : rng.range(0.45, 0.85)
        let snow = sc.snow || ["arctic night", "northern dawn"].contains(m.name) ? rng.range(0.6, 1.0) : 0.0

        // the ridges, far to near; in a water scene the nearest stands on this side of the water
        func mixf(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        func quant(_ f: Double) -> Double { Double(max(2, Int((f * 6 / 2).rounded()) * 2)) / 6 }   // whole repeats every 6 widths
        let n = sc.styles.count
        let front = water ? 1 : 0
        let nb = n - front
        var made: [SIMD4<Float>] = []
        for (i, st) in sc.styles.enumerated() {
            let z = n > 1 ? Double(i) / Double(n - 1) : 1
            let isFront = i >= nb
            let base: Double
            if water {
                let zb = nb > 1 ? Double(i) / Double(nb - 1) : 0
                base = isFront ? units + 0.05 : mixf(horizon + 0.05, waterLine + 0.005, zb)
            } else {
                base = mixf(horizon + 0.06, units + 0.05, pow(z, 1.15))
            }
            var amp: Double, f: Double
            switch st {
            case 0:
                amp = mixf(rng.range(0.26, 0.40), rng.range(0.16, 0.26), z)
                f = mixf(rng.range(1.0, 1.8), rng.range(0.7, 1.1), z)
            case 1:
                amp = mixf(rng.range(0.12, 0.2), rng.range(0.22, 0.34), z)
                f = mixf(rng.range(1.0, 1.8), rng.range(0.6, 1.0), z)
            case 2:
                amp = mixf(rng.range(0.10, 0.16), rng.range(0.16, 0.24), z)
                f = mixf(rng.range(1.6, 2.6), rng.range(0.7, 1.2), z)
            case 3:
                amp = mixf(rng.range(0.10, 0.16), rng.range(0.16, 0.26), z)
                f = mixf(rng.range(3.0, 4.5), rng.range(1.2, 2.0), z)
            case 4:
                amp = rng.range(0.06, 0.12)
                f = rng.range(3.0, 5.0)
            case 5:
                amp = mixf(rng.range(0.06, 0.12), rng.range(0.14, 0.24), z)
                f = mixf(rng.range(1.2, 2.0), rng.range(0.6, 1.0), z)
            default:
                amp = mixf(rng.range(0.2, 0.28), rng.range(0.36, 0.5), z)
                f = mixf(rng.range(1.4, 2.0), rng.range(0.7, 1.0), z)
            }
            if water && !isFront { amp *= 0.85 }
            if isFront {
                switch st {
                case 5:                                 // headlands rising from the sea
                    amp = rng.range(0.30, 0.42)
                    f = rng.range(0.67, 1.0)
                case 3:                                 // trees along the near shore
                    amp = rng.range(0.16, 0.24)
                    f = rng.range(1.6, 2.4)
                default:
                    amp = rng.range(0.10, 0.16)
                    f = rng.range(0.8, 1.2)
                }
            }
            made.append(SIMD4(Float(base), Float(amp), Float(quant(f)), Float(st)))
        }
        layers = made

        var particle = 0.0
        if m.name == "arctic night" {
            particle = 2
        } else if m.name == "sakura" {
            particle = 3
        } else if ["twilight lilac", "moonlit silver"].contains(m.name) && ["pines", "highlands", "lake"].contains(sc.name) {
            particle = 4
        } else if !night && rng.unit() < 0.6 {
            particle = 1
        }
        particles = Int(particle)
        let seed = rng.range(0.0, 97.0)
        name = m.words[rng.pick(m.words.count)] + " " + sc.nouns[rng.pick(sc.nouns.count)]
        timeOffset = rng.range(0, 4096)

        func c(_ hex: String, _ w: Double) -> SIMD4<Float> {
            let v = LandscapeDesign.rgb01(hex)
            return SIMD4(Float(v.0), Float(v.1), Float(v.2), Float(w))
        }
        var p: [SIMD4<Float>] = [
            c(m.zenith, night ? 1 : 0),
            c(m.upper, 0.5),                                            // .w: the Moon's lit fraction, each frame
            c(m.horizon, horizon),
            c(m.sun, size),
            SIMD4(Float(sx), Float(sy), Float(glow), night ? 1 : 0),
            c(m.haze, mist),
            c(m.mist, rays),
            c(m.far, rim),
            c(m.near, Double(n)),
            c(m.cloudLit, clouds),
            c(m.cloudShade, cloudY),
            c("5CF2B0", m.aurora),
            c("9B6CFF", m.stars),
            c(m.water, waterLine),
            c(m.snow, snow),
            c(m.particle, particle),
        ]
        for i in 0..<6 { p.append(i < made.count ? made[i] : SIMD4(0, 0, 1, 0)) }
        p.append(SIMD4(0.5, 0.5, 0, 0))                                 // pointer x, y, strength, time: each frame
        p.append(SIMD4(0.002, Float(seed), Float(units), 1))            // pixel size and the Moon's side: each frame
        p.append(SIMD4(0, 0, 0, 0))
        params = p
    }

    static func rgb01(_ hex: String) -> (Double, Double, Double) {
        let v = UInt32(hex, radix: 16) ?? 0
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func rgb(_ hex: String) -> CoverRGB {
        let v = rgb01(hex)
        return (v.0 * 255, v.1 * 255, v.2 * 255)
    }

    /// The colours the lettering and its veil take from this landscape.
    var palette: CoverPalette {
        CoverPalette(top: LandscapeDesign.rgb(mood.zenith), bottom: LandscapeDesign.rgb(mood.dark ? mood.near : mood.mist),
                     glows: [], ink: LandscapeDesign.rgb(mood.ink), dark: mood.dark)
    }

    /// Shown for the moment before the GPU's first picture arrives.
    var backdrop: LinearGradient {
        let h = horizonY / LandscapeDesign.units
        return LinearGradient(stops: [
            .init(color: CoverPalette.rgb(LandscapeDesign.rgb(mood.zenith)), location: 0),
            .init(color: CoverPalette.rgb(LandscapeDesign.rgb(mood.horizon)), location: h * 0.9),
            .init(color: CoverPalette.rgb(LandscapeDesign.rgb(mood.far)), location: min(0.95, h + 0.1)),
            .init(color: CoverPalette.rgb(LandscapeDesign.rgb(mood.near)), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    // MARK: Hover caption

    /// What is under the pointer (`point` in cover units), and the real Moon tonight.
    func captionLines(at point: CGPoint, visits: Int, sky: SkyNow) -> (String, String, String) {
        let x = Double(point.x), y = Double(point.y)
        let night = mood.moon
        let dSun = hypot(x - Double(sun.x), y - Double(sun.y))
        var detail: String
        if dSun < sunSize * 1.6 {
            detail = night ? "The Moon, \(Int((sky.moonIllum * 100).rounded()))% lit tonight, as it really is"
                           : (Double(sun.y) > horizonY * 0.75 ? "The sun low over the far ridges" : "The sun, high in a hazy sky")
        } else if waterY > 0 && y > waterY {
            detail = night ? "Still water holding the moonlight" : "Still water holding the sky"
        } else if y < horizonY * 0.8 {
            if mood.aurora > 0 && y > horizonY * 0.35 {
                detail = "Aurora: curtains of oxygen light a hundred kilometres up"
            } else if night {
                detail = particles == 2 ? "Snow falling under the stars" : "Stars over the \(scene.nouns[0].lowercased())"
            } else if particles == 1 && visits % 2 == 1 {
                detail = "Birds crossing on the high air"
            } else if particles == 3 {
                detail = "Blossom drifting on the spring wind"
            } else if clouds > 0.15 {
                detail = "Cloud drifting with the high wind"
            } else {
                detail = "Light falling through the haze"
            }
        } else {
            switch scene.name {
            case "dunes": detail = "Wind-built dunes, their slip faces in shadow"
            case "pines": detail = particles == 4 ? "Fireflies among the pines" : "Pines standing in the valley fog"
            case "cloudsea": detail = "A sea of cloud, the peaks rising out of it"
            case "coast": detail = "Headlands stepping out into the sea"
            case "highlands": detail = "Downs and woods, the mist lying in the hollows"
            case "peaks": detail = "Snow on the high peaks"
            case "lake": detail = "Mountains beyond the water, mist along the shore"
            default: detail = "Ridge behind ridge, each paler in the haze"
            }
        }
        let pct = Int((sky.moonIllum * 100).rounded())
        return (name, detail, "Tonight: \(sky.moonPhaseName) · \(pct)% lit")
    }
}

final class LandscapeCache {
    static let shared = LandscapeCache()
    private var designs: [String: LandscapeDesign] = [:]

    func design(title: String, author: String) -> LandscapeDesign {
        let key = title + "\u{1F}" + author
        if let d = designs[key] { return d }
        let d = LandscapeDesign(title: title, author: author)
        designs[key] = d
        return d
    }
}
