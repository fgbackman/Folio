import SwiftUI

/// The stars and the lines of the figure over a cover's painted sky, drifting and twinkling.
/// The Mac draws its moving sky on the GPU; this is the drawn stand-in for iPhone and iPad.
struct CoverStars: View {
    let design: CoverDesign
    let moving: Bool
    let awake: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !(moving && awake))) { timeline in
            let t = moving ? timeline.date.timeIntervalSince(CoverClock.start) : 0
            Canvas { ctx, size in
                guard size.width > 2 else { return }
                let d = design
                let p = CoverPainter(d, size)
                let stars = d.field.stars
                let points = stars.map { p.pt(p.starPoint($0, t)) }
                var lines = Path()
                for (a, b) in d.field.segs where a < stars.count && b < stars.count {
                    lines.move(to: points[a])
                    lines.addLine(to: points[b])
                }
                ctx.stroke(lines, with: .color(p.ink((1, 1, 1), 0.30)), lineWidth: max(0.5, size.width * 0.003))
                for (i, s) in stars.enumerated() {
                    let c = points[i]
                    let r = max(0.35, p.starRadius(s.mag))
                    if c.x < -r || c.y < -r || c.x > size.width + r || c.y > size.height + r { continue }
                    // each star keeps its own slow beat
                    let beat = moving ? 0.80 + 0.20 * sin(t * (0.6 + Double(i % 7) * 0.17) + Double(i) * 1.7) : 0.95
                    if r > 1.1 {
                        let g = r * 3.2
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - g, y: c.y - g, width: 2 * g, height: 2 * g)),
                                 with: .radialGradient(Gradient(colors: [p.ink(s.rgb, 0.28 * beat), p.ink(s.rgb, 0)]),
                                                       center: c, startRadius: 0, endRadius: g))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(p.ink(s.rgb, beat)))
                }
            }
        }
    }
}
