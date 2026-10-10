// The GPU programs that draw the moving sky. They are compiled once at launch from this source,
// so the app needs no separate Metal build step.
//
//  prim   – soft glows, discs, rings and line segments, one instanced quad each
//  mesh   – coloured triangles for everything with an irregular outline (tails, trails, aurora)
//  star   – the constellation's stars, straight from the catalogue buffer: parallax, twinkle,
//           variable-star light curves and the gravitational lens are all worked out here
//  moon   – the Moon's disc, phase, maria, earthshine and Earth's shadow, per pixel
//
// Everything is in points with the origin at the top left; colours are sRGB and blended as such,
// to match the painted layer underneath.

enum CoverShaders {
    static let source = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;            // points
    float scale;            // pixels per point
    float w;                // points per cover unit
    float t;                // seconds, wrapped once a day
    float night;
    float dark;
    float lensStrength;
    float2 lensCenter;      // cover units
    float lensTheta;
    float dimming;
    float2 drift;           // cover units, for a star of parallax 1
    float starPass;         // 0 the star itself, 1 and 2 its two lensed images
    float units;            // cover height in cover units
    float4 ink;
};

struct MoonUniforms {
    float2 center;          // points
    float R;
    float k;                // illuminated fraction
    float side;             // +1 lit on the right, -1 on the left
    float stage;
    float2 lib;             // libration, lunar radii
    float4 disc;            // the night side
    float es;               // earthshine
    float eclipse;
    float fade;
    float pad;
    float2 shadow;          // centre of Earth's shadow, points
    float2 pad2;
    float4 rays[3];         // lengths of Tycho's rays
};

static inline float4 premul(float4 c) { return float4(c.rgb * c.a, c.a); }
static inline float4 over(float4 dst, float4 src) { return src + dst * (1.0 - src.a); }
static inline float4 screen(float4 dst, float4 src) { return dst + src - dst * src; }
static inline float cover(float dist, float scale) { return clamp(0.5 - dist * scale, 0.0, 1.0); }

static inline float4 clip(float2 p, float2 size) {
    return float4(p.x / size.x * 2.0 - 1.0, 1.0 - p.y / size.y * 2.0, 0.0, 1.0);
}

// The falloff of a soft glow: full at the centre, gone at the rim.
static inline float glowCurve(float d) {
    if (d < 0.32) return mix(1.0, 0.55, d / 0.32);
    if (d < 0.66) return mix(0.55, 0.18, (d - 0.32) / 0.34);
    if (d < 1.0) return mix(0.18, 0.0, (d - 0.66) / 0.34);
    return 0.0;
}

// MARK: prim

struct Prim { float4 a; float4 b; float4 c0; float4 c1; float4 p; };

struct PrimOut {
    float4 position [[position]];
    float2 pos;
    float4 a [[flat]];
    float4 b [[flat]];
    float4 c0 [[flat]];
    float4 c1 [[flat]];
    float4 p [[flat]];
};

vertex PrimOut prim_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device Prim *prims [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    Prim pr = prims[iid];
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    int type = int(pr.b.y);
    float pad = 1.0 / u.scale;
    float2 pos;
    if (type == 4) {
        float2 d = pr.a.zw - pr.a.xy;
        float len = length(d);
        float2 ax = len > 1e-5 ? d / len : float2(1.0, 0.0);
        float2 nx = float2(-ax.y, ax.x);
        float hw = pr.b.z * 0.5 + pad;
        pos = (pr.a.xy + pr.a.zw) * 0.5 + ax * corner.x * (len * 0.5 + hw) + nx * corner.y * hw;
    } else if (type == 3) {
        pos = pr.a.xy + corner * (pr.a.z + pr.a.w * 0.5 + pad);
    } else {
        pos = pr.a.xy + corner * (max(pr.a.z, pr.a.w) + pad);
    }
    PrimOut o;
    o.position = clip(pos, u.size);
    o.pos = pos;
    o.a = pr.a; o.b = pr.b; o.c0 = pr.c0; o.c1 = pr.c1; o.p = pr.p;
    return o;
}

fragment float4 prim_fragment(PrimOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    int type = int(in.b.y);
    float s = u.scale;
    if (type == 4) {                                     // line segment, round caps, colour c0 → c1
        float2 pa = in.pos - in.a.xy, ba = in.a.zw - in.a.xy;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
        float g = in.b.w > 0.5 ? abs(2.0 * h - 1.0) : h;   // or c0 in the middle, c1 at both ends
        return mix(premul(in.c0), premul(in.c1), g) * cover(length(pa - ba * h) - in.b.z * 0.5, s);
    }
    float2 l = in.pos - in.a.xy;
    if (type == 3) {                                     // ring
        return premul(in.c0) * cover(abs(length(l) - in.a.z) - in.a.w * 0.5, s);
    }
    float ca = cos(in.b.x), sa = sin(in.b.x);
    float2 q = float2(l.x * ca + l.y * sa, -l.x * sa + l.y * ca);
    float2 rad = max(in.a.zw, float2(1e-4));
    float d = length(q / rad);
    if (type == 0) return premul(in.c0) * glowCurve(d);  // glow
    if (type == 1) return premul(in.c0) * cover((d - 1.0) * min(rad.x, rad.y), s);   // disc
    if (type == 2) return d < 1.0 ? mix(premul(in.c0), premul(in.c1), d) : float4(0.0);   // radial fade
    // the Sun's disc with the Moon's bite out of it
    float sun = cover(length(l) - in.a.z, s);
    float moon = cover(length(in.pos - in.p.xy) - in.p.z, s);
    return premul(mix(in.c0, in.c1, min(d, 1.0))) * sun * (1.0 - moon);
}

// MARK: mesh

struct MeshVertex { float2 pos; float2 edge; float4 color; };

struct MeshOut {
    float4 position [[position]];
    float2 edge;
    float4 color;
};

vertex MeshOut mesh_vertex(uint vid [[vertex_id]], const device MeshVertex *verts [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    MeshVertex v = verts[vid];
    MeshOut o;
    o.position = clip(v.pos, u.size);
    o.edge = v.edge;
    o.color = premul(v.color);
    return o;
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    // edge.x runs from -1 to 1 across a stroke, edge.y is its half width: feather the sides
    float a = in.edge.y > 0.0 ? clamp((1.0 - abs(in.edge.x)) * in.edge.y * u.scale, 0.0, 1.0) : 1.0;
    return in.color * a;
}

// MARK: star

struct Star {
    float4 s0;      // x, y (cover units), magnitude, parallax
    float4 s1;      // r, g, b, kind of variable star
    float4 s2;      // twinkle period, twinkle phase
};

struct StarOut {
    float4 position [[position]];
    float2 local;                   // points from the star's centre
    float3 rgb [[flat]];
    float4 shape [[flat]];          // radius, magnitude, alpha, stretched
    float4 lens [[flat]];           // cos, sin of the image's angle; radial and tangential stretch
};

static float liveMag(float mag, int variable, float t, float dimming) {
    const float tau = 6.283185307;
    if (variable == 1) {            // Algol
        float ph = fract(t / 60.0 + 0.37);
        float d1 = (ph - 0.5) / 0.028, d2 = min(ph, 1.0 - ph) / 0.028;
        return 2.09 + 1.3 * exp(-0.5 * d1 * d1) + 0.06 * exp(-0.5 * d2 * d2);
    }
    if (variable == 2) {            // Mira
        float ph = fract(t / 120.0 + 0.2);
        return 6.0 - 3.6 * cos(tau * ph + 0.35 * sin(tau * ph));
    }
    if (variable == 3) {            // Delta Cephei
        float ph = fract(t / 45.0);
        return 4.37 - 0.9 * (ph < 0.25 ? ph / 0.25 : 1.0 - (ph - 0.25) / 0.75);
    }
    if (variable == 4) return mag + 1.15 * dimming + 0.12 * sin(tau * t / 90.0);   // Betelgeuse
    return mag;
}

vertex StarOut star_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device Star *stars [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    const float tau = 6.283185307;
    Star st = stars[iid];
    StarOut o;
    o.position = float4(2.0, 2.0, 0.0, 1.0);            // off screen unless the star is drawn
    o.local = float2(0.0);
    o.rgb = st.s1.rgb;
    o.shape = float4(0.0);
    o.lens = float4(1.0, 0.0, 1.0, 1.0);

    float2 p = st.s0.xy + u.drift * st.s0.w;
    if (p.x < -0.05 || p.x > 1.05 || p.y < -0.05 || p.y > u.units + 0.05) return o;
    int variable = int(st.s1.w);
    float mag = variable > 0 ? liveMag(st.s0.z, variable, u.t, u.dimming) : st.s0.z;
    if (mag > 6.9) return o;
    float alpha = 1.0;
    if (mag < 4.3 && u.t > 0.0) alpha = 0.86 + 0.14 * sin(tau * u.t / st.s2.x + st.s2.y);

    // The point-mass lens: a source at angle β from the lens appears as two images at
    // θ± = θE (u ± √(u² + 4)) / 2 with u = β / θE, stretched along the ring by θ/β and across it by dθ/dβ.
    int pass = int(u.starPass);
    float tangential = 1.0, radial = 1.0;
    float2 dir = float2(1.0, 0.0);
    if (u.lensStrength > 0.0) {
        float2 dd = p - u.lensCenter;
        float beta = length(dd);
        bool near = beta < u.lensTheta * 3.5;
        if (pass == 0) {
            if (near) alpha *= 1.0 - u.lensStrength;
        } else {
            if (!near) return o;
            float uu = max(0.03, beta / u.lensTheta);
            float root = sqrt(uu * uu + 4.0);
            float sign = pass == 1 ? 1.0 : -1.0;
            float th = u.lensTheta * (uu + sign * root) / 2.0;
            if (beta > 1e-9) dir = dd / beta;
            tangential = clamp(abs(th) / max(1e-6, beta), 0.2, 8.0);
            radial = clamp(0.5 * (1.0 + sign * uu / root), 0.15, 2.5);
            p = u.lensCenter + dir * th;
            alpha *= u.lensStrength;
        }
    } else if (pass != 0) {
        return o;
    }
    if (alpha < 0.004) return o;

    float r = max(0.35, u.w * 0.0028 * pow(pow(10.0, -0.4 * (mag - 6.5)), 0.22));
    bool stretched = abs(tangential - 1.0) > 0.05 || abs(radial - 1.0) > 0.05;
    float reach = r;
    if (stretched) {
        reach = r * 2.2 * max(tangential, radial);
    } else if (mag < 4.3) {
        reach = r * (mag < 0.6 ? 7.0 : (mag < 1.5 ? 6.0 : (mag < 3.0 ? 4.2 : 3.2)));
    }
    if (u.dark < 0.5) reach = max(reach, r * 3.2 * (stretched ? max(tangential, radial) : 1.0));
    reach += 1.0 / u.scale;

    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    o.position = clip(p * u.w + corner * reach, u.size);
    o.local = corner * reach;
    o.shape = float4(r, mag, alpha, stretched ? 1.0 : 0.0);
    o.lens = float4(dir.x, dir.y, radial, tangential);
    return o;
}

fragment float4 star_fragment(StarOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float r = in.shape.x, mag = in.shape.y, alpha = in.shape.z;
    bool stretched = in.shape.w > 0.5;
    bool dark = u.dark > 0.5;
    float s = u.scale;
    float2 l = in.local;
    float2 q = float2(l.x * in.lens.x + l.y * in.lens.y, -l.x * in.lens.y + l.y * in.lens.x);
    float2 axes = stretched ? in.lens.zw : float2(1.0);
    float d = length(q / axes);                         // distance in units where the star's radius is `radius`
    float thin = min(axes.x, axes.y);
    #define SHAPE(radius) cover((d - (radius)) * thin, s)

    float4 acc = float4(0.0);
    float night = u.night;
    if (!dark) {
        // twilight: the real star pattern as soft points of ink, the brightest strongest
        if (mag < 4.9 && night < 0.98) {
            bool plain = !stretched && alpha >= 0.8;
            float a = (mag < 2.0 ? 0.66 : (mag < 3.4 ? 0.52 : 0.34)) * (1.0 - night) * (plain ? 1.0 : alpha);
            float3 col = plain ? mix(u.ink.rgb, float3(0.5, 0.55, 0.7), 0.15) : mix(u.ink.rgb, in.rgb, 0.18);
            if (mag < 2.2) {
                acc = premul(float4(mix(u.ink.rgb, in.rgb, 0.3), 0.09 * alpha * (1.0 - night))) * SHAPE(r * 3.2);
            }
            acc = over(acc, premul(float4(col, a)) * SHAPE(r * 1.1));
        }
        if (night <= 0.02) return acc;
    }
    float a = dark ? alpha : alpha * night;
    float4 light;
    if (mag >= 4.3) {
        float level = mag < 5.0 ? 0.8 : (mag < 5.7 ? 0.6 : 0.42);
        light = premul(float4(0.92, 0.94, 1.0, level * a)) * SHAPE(r);
    } else {
        float3 core = mix(in.rgb, float3(1.0), 0.55);
        if (stretched) {
            light = premul(float4(in.rgb, 0.18 * a)) * SHAPE(r * 2.2);
            float4 c = premul(float4(core, a)) * SHAPE(r);
            light = dark ? screen(light, c) : over(light, c);
        } else {
            float len = length(l);
            float reach = r * (mag < 1.5 ? 6.0 : (mag < 3.0 ? 4.2 : 3.2));
            light = premul(float4(in.rgb, (mag < 1.5 ? 0.32 : 0.22) * a)) * glowCurve(len / reach);
            float4 c = premul(float4(core, a)) * cover(len - r, s);
            light = dark ? screen(light, c) : over(light, c);
            if (mag < 0.6) {
                // diffraction spikes on the very brightest
                float span = r * 7.0;
                float2 al = abs(l);
                float dh = length(float2(max(al.x - span, 0.0), al.y));
                float dv = length(float2(al.x, max(al.y - span, 0.0)));
                float line = cover(min(dh, dv) - max(0.4, r * 0.25) * 0.5, s);
                float4 sp = premul(float4(in.rgb, 0.2 * a)) * line * clamp(1.0 - len / span, 0.0, 1.0);
                light = dark ? screen(light, sp) : over(light, sp);
            }
        }
    }
    return dark ? screen(acc, light) : over(acc, light);
}

// MARK: moon

struct MoonOut {
    float4 position [[position]];
    float2 pos;
};

vertex MoonOut moon_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(1)]],
                           constant MoonUniforms &m [[buffer(2)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 pos = m.center + corner * (m.R * 1.1 + 4.0);
    MoonOut o;
    o.position = clip(pos, u.size);
    o.pos = pos;
    return o;
}

// The near side's maria (x, y, rx, ry in lunar radii; north up, as seen with the naked eye).
constant float4 mariaTable[11] = {
    float4(-0.30, -0.38, 0.30, 0.26),   // Mare Imbrium
    float4(0.14, -0.38, 0.17, 0.16),    // Mare Serenitatis
    float4(0.30, -0.08, 0.22, 0.17),    // Mare Tranquillitatis
    float4(0.66, -0.30, 0.11, 0.10),    // Mare Crisium
    float4(0.56, 0.18, 0.13, 0.17),     // Mare Fecunditatis
    float4(0.36, 0.32, 0.09, 0.10),     // Mare Nectaris
    float4(-0.62, -0.05, 0.26, 0.42),   // Oceanus Procellarum
    float4(-0.18, 0.38, 0.17, 0.13),    // Mare Nubium
    float4(-0.50, 0.38, 0.09, 0.09),    // Mare Humorum
    float4(-0.05, -0.72, 0.38, 0.06),   // Mare Frigoris
    float4(0.0, -0.17, 0.08, 0.06),     // Mare Vaporum
};

// Bright young craters: Tycho (with its rays near full Moon), Copernicus, Kepler, Aristarchus.
constant float3 craterTable[4] = {
    float3(-0.14, 0.72, 0.55), float3(-0.30, -0.05, 0.35), float3(-0.55, -0.07, 0.25), float3(-0.68, -0.38, 0.5),
};

static float4 maria(float2 p, constant MoonUniforms &m, float alpha, float full, bool dark, float s) {
    const float tau = 6.283185307;
    float R = m.R;
    float4 acc = float4(0.0);
    float a = (dark ? 0.42 : 0.5) * alpha;
    for (int i = 0; i < 11; i++) {
        float4 q = mariaTable[i];
        float d = length((p - (q.xy + m.lib) * R) / (q.zw * R));
        if (d < 1.0) {
            float g = d < 0.55 ? mix(1.0, 0.85, d / 0.55) : mix(0.85, 0.0, (d - 0.55) / 0.45);
            acc = over(acc, premul(float4(0.52, 0.55, 0.6, a * g)));
        }
    }
    for (int i = 0; i < 4; i++) {
        float3 q = craterTable[i];
        float rr = max(0.4, R * (i == 0 ? 0.045 : 0.03));
        acc = over(acc, premul(float4(1.0, 1.0, 0.98, q.z * alpha)) * cover(length(p - (q.xy + m.lib) * R) - rr, s));
    }
    if (full > 0.85) {
        float2 pa = p - (float2(-0.14, 0.72) + m.lib) * R;
        float nearest = 1e9;
        for (int i = 0; i < 9; i++) {
            float ang = float(i) / 9.0 * tau + 0.3;
            float2 b = float2(cos(ang), sin(ang)) * R * (0.4 + 0.5 * m.rays[i / 4][i % 4]);
            float h = clamp(dot(pa, b) / dot(b, b), 0.0, 1.0);
            nearest = min(nearest, length(pa - b * h));
        }
        float line = cover(nearest - max(0.4, R * 0.02) * 0.5, s);
        acc = over(acc, premul(float4(1.0, 1.0, 0.97, 0.12 * alpha * (full - 0.85) / 0.15)) * line);
    }
    return acc;
}

fragment float4 moon_fragment(MoonOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                              constant MoonUniforms &m [[buffer(2)]]) {
    const float pi = 3.14159265;
    bool dark = u.dark > 0.5;
    float s = u.scale;
    float R = m.R, k = m.k, side = m.side;
    float2 p = in.pos - m.center;
    float len = length(p);
    float disc = cover(len - R, s);
    int stage = int(m.stage);

    if (stage == 0) {
        // The sunlit part: the limb on one side, the terminator (half an ellipse) on the other.
        // How much of this pixel's width lies between them.
        float tx = 1.0 - 2.0 * k;
        float chord = sqrt(max(R * R - p.y * p.y, 0.0));
        float reach = 0.5 / s;
        float lit = clamp(min(side * p.x + reach, chord) - max(side * p.x - reach, tx * chord), 0.0, 2.0 * reach) * s;
        float4 acc = premul(m.disc) * disc;
        if (dark) {
            // earthshine: sunlight bounced off Earth lights the night side, most of all around new Moon
            float g = clamp(length(p - float2(-side * R * 0.3, 0.0)) / (R * 1.3), 0.0, 1.0);
            acc = over(acc, premul(mix(float4(0.64, 0.7, 0.82, m.es), float4(0.5, 0.56, 0.7, m.es * 0.5), g)) * disc);
            if (k < 0.5) acc = over(acc, maria(p, m, 0.16 * (1.0 - 2.0 * k), 0.0, dark, s) * disc);
        } else if (k > 0.15) {
            // a soft shadow round the lit part, so a pale Moon still reads against a pale sky
            float poles = min(length(p - float2(0.0, R)), length(p + float2(0.0, R)));
            float limb = side * p.x >= 0.0 ? abs(len - R) : poles;
            float ex = max(abs(tx) * R, R * 1e-3);
            float f = length(p / float2(ex, R));
            float slope = length(float2(p.x / (ex * ex), p.y / (R * R))) / max(f, 1e-5);
            float term = side * tx * p.x >= 0.0 ? abs(f - 1.0) / max(slope, 1e-6) : poles;
            float edge = min(limb, term);
            acc = over(acc, premul(float4(u.ink.rgb, 0.05)) * cover(edge - max(2.0, R * 0.16) * 0.5, s));
            acc = over(acc, premul(float4(u.ink.rgb, 0.07)) * cover(edge - max(1.0, R * 0.07) * 0.5, s));
        }
        float g = clamp(length(p - float2(side * R * 0.35, -R * 0.1)) / (R * 1.4), 0.0, 1.0);
        float4 bright = float4(0.98, 0.97, 0.93, dark ? 0.98 : 0.96), shade = float4(0.84, 0.83, 0.8, dark ? 0.95 : 0.9);
        acc = over(acc, premul(mix(bright, shade, g)) * lit);
        if (k > 0.04) acc = over(acc, maria(p, m, 1.0, k, dark, s) * lit);
        return acc;
    }

    // A thin crescent is mostly bright limb: its distance from this pixel
    float limb = 1e9;
    float fade = 1.0 - k / 0.3;
    if (k < 0.3) {
        float span = pi * 0.44;
        if (abs(atan2(p.y, side * p.x)) <= span) {
            limb = abs(len - R);
        } else {
            float2 tip = float2(side * R * cos(span), R * sin(span));
            limb = min(length(p - tip), length(p - float2(tip.x, -tip.y)));
        }
    }

    if (stage == 1) {
        // let the limb glow, so the crescent reads at any size
        float4 wide = premul(float4(1.0, 0.97, 0.9, (dark ? 0.12 : 0.2) * fade)) * cover(limb - max(3.0, R * 0.16) * 0.5, s);
        float4 tight = premul(float4(1.0, 0.97, 0.9, (dark ? 0.28 : 0.4) * fade)) * cover(limb - max(1.4, R * 0.07) * 0.5, s);
        return dark ? screen(wide, tight) : over(wide, tight);
    }

    float4 acc = float4(0.0);
    if (k < 0.3) acc = premul(float4(1.0, 0.99, 0.95, 0.9 * fade)) * cover(limb - max(0.6, R * 0.022) * 0.5, s);
    if (dark) acc = over(acc, premul(float4(1.0, 1.0, 1.0, 0.05)) * cover(abs(len - R) - max(0.5, R * 0.012) * 0.5, s));
    if (m.eclipse > 0.5) {
        // Earth's shadow: a grey penumbra, a copper umbra, and the turquoise fringe the ozone layer leaves
        float ds = length(in.pos - m.shadow);
        float f = m.fade;
        float g = ds / (R * 4.7);
        float pen = g < 0.55 ? 0.45 : (g < 1.0 ? 0.45 * (1.0 - (g - 0.55) / 0.45) : 0.0);
        acc = over(acc, premul(float4(0.1, 0.08, 0.1, pen * f)) * disc);
        g = ds / (R * 2.7);
        float4 umbra = float4(0.0);
        if (g < 0.8) umbra = mix(float4(0.30, 0.07, 0.04, 0.9 * f), float4(0.55, 0.16, 0.07, 0.86 * f), g / 0.8);
        else if (g < 0.97) umbra = mix(float4(0.55, 0.16, 0.07, 0.86 * f), float4(0.75, 0.32, 0.14, 0.8 * f), (g - 0.8) / 0.17);
        else if (g < 1.0) umbra = float4(0.75, 0.32, 0.14, 0.8 * f * (1.0 - (g - 0.97) / 0.03));
        acc = over(acc, premul(umbra) * disc);
        acc = over(acc, premul(float4(0.35, 0.78, 0.86, 0.28 * f)) * cover(abs(ds - R * 2.62) - max(0.6, R * 0.12) * 0.5, s) * disc);
    }
    return acc;
}
"""
}
