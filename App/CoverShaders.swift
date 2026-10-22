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

    /// The landscape covers, compiled as a library of their own so that a problem here can't stop the skies.
    /// Every pixel is worked out from a few dozen numbers per cover (LandscapeDesign): ridges are 1D fractals
    /// drifting at their own depths, mist is warped 2D noise, water reflects the scene above it through ripples.
    /// Each cover is one quad over its cell, and the result is opaque. Everything that moves repeats exactly
    /// every 4096 seconds and every six cover widths, so the picture never jumps however long Folio runs.
    static let landscapeSource = """
#include <metal_stdlib>
using namespace metal;

#define FN static inline
// ---- Landscape cover core (shared by the Metal renderer and the WebGL preview) ----
// Cover units: x 0..1 across, y 0..units down (units = 1.5). Colours are sRGB.
// Everything that moves repeats exactly every 4096 s (phase 0..1) and every XP cover widths,
// so the picture never jumps however long the app runs.

#define PI 3.14159265
#define TAU 6.2831853
#define XP 6.0

struct Land {
    float3 zenith; float night;
    float3 upper; float moonK;
    float3 horizon; float horizonY;
    float3 sunColor; float sunSize;
    float2 sunPos; float sunGlow; float isMoon;
    float3 haze; float mistAmount;
    float3 mist; float rays;
    float3 far; float rim;
    float3 near; float count;
    float3 cloudLit; float clouds;
    float3 cloudShade; float cloudY;
    float3 auroraA; float aurora;
    float3 auroraB; float stars;
    float3 water; float waterY;
    float3 snow; float snowAmount;
    float3 particle; float particleKind;
    float4 layer[6];                    // base y, height, frequency (cycles per cover width), style
    float2 hover; float hoverS; float phase;
    float px; float seed; float units; float moonSide;
    float4 extra;                       // x: lone tree position (0 none), y: tree size
};

FN float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

FN float hash12(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, float3(p3.y, p3.z, p3.x) + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

FN float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, float3(p3.y, p3.z, p3.x) + 33.33);
    return fract(float2((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y));
}

FN float wrapf(float x, float p) { return x - p * floor(x / p); }
FN float fade5(float f) { return f * f * f * (f * (f * 6.0 - 15.0) + 10.0); }
FN float sq(float x) { return x * x; }

// 1D gradient noise, -1..1, repeating every `period` units (a whole number).
FN float gnoise1(float x, float period, float s) {
    float i = floor(x);
    float f = x - i;
    float g0 = hash11(wrapf(i, period) * 1.37 + s) * 2.0 - 1.0;
    float g1 = hash11(wrapf(i + 1.0, period) * 1.37 + s) * 2.0 - 1.0;
    return mix(g0 * f, g1 * (f - 1.0), fade5(f)) * 2.0;
}

// 2D gradient noise, about -0.7..0.7, repeating every `period` units across.
FN float gnoise2(float2 p, float period, float s) {
    float2 i = floor(p);
    float2 f = p - i;
    float x0 = wrapf(i.x, period), x1 = wrapf(i.x + 1.0, period);
    float2 ga = hash22(float2(x0, i.y) + s) * 2.0 - 1.0;
    float2 gb = hash22(float2(x1, i.y) + s) * 2.0 - 1.0;
    float2 gc = hash22(float2(x0, i.y + 1.0) + s) * 2.0 - 1.0;
    float2 gd = hash22(float2(x1, i.y + 1.0) + s) * 2.0 - 1.0;
    float va = dot(ga, f);
    float vb = dot(gb, f - float2(1.0, 0.0));
    float vc = dot(gc, f - float2(0.0, 1.0));
    float vd = dot(gd, f - float2(1.0, 1.0));
    float ux = fade5(f.x), uy = fade5(f.y);
    return mix(mix(va, vb, ux), mix(vc, vd, ux), uy);
}

FN float fbm2(float2 p, float period, float s, int octaves) {
    float v = 0.0, a = 0.5;
    for (int k = 0; k < 5; k++) {
        if (k >= octaves) break;
        v += a * gnoise2(p, period, s + float(k) * 19.19);
        p = p * 2.0 + float2(17.0, 3.7);
        period *= 2.0;
        a *= 0.5;
    }
    return v;
}

// ---- ridgelines: height 0..1 at noise coordinate x (period in the same units) ----

// Mountains: a ridged fractal, smoother the farther away (fewer octaves), with broad massifs.
FN float ridgeMountain(float x, float period, float s, float detail) {
    x += 0.32 * gnoise1(x * 0.5, period * 0.5, s + 17.0);          // lean the peaks this way and that
    float mass = 0.5 + 0.5 * gnoise1(x * 0.5, period * 0.5, s + 41.0);
    float v = 0.0, a = 0.5, w = 1.0, total = 0.0;
    for (int k = 0; k < 6; k++) {
        if (float(k) >= detail) break;
        float n = 1.0 - abs(gnoise1(x, period, s + float(k) * 7.31));
        n = n * n * 0.55 + n * 0.45;
        v += a * n * w;
        total += a;
        w = clamp(n * 1.25, 0.25, 1.0);
        x *= 2.0;
        period *= 2.0;
        a *= 0.47;
    }
    float h = 0.55 * v / total + 0.45 * mass;
    return clamp(pow(h, 1.3) * 1.25, 0.0, 1.0);
}

FN float ridgeHills(float x, float period, float s) {
    float v = 0.0, a = 0.5;
    for (int k = 0; k < 4; k++) {
        v += a * gnoise1(x, period, s + float(k) * 5.17);
        x *= 2.0;
        period *= 2.0;
        a *= 0.38;
    }
    return clamp(0.5 + 0.62 * v, 0.0, 1.0);
}

// Dunes: long windward slopes and short slip faces, crests of different heights.
FN float ridgeDunes(float x, float period, float s) {
    float w = x + 0.3 * gnoise1(x * 0.5, period * 0.5, s + 3.3);
    float cell = floor(w);
    float f = w - cell;
    float c = 0.76;
    float prof = f < c ? smoothstep(0.0, 1.0, f / c) : smoothstep(0.0, 1.0, (1.0 - f) / (1.0 - c));
    float hgt = 0.5 + 0.5 * hash11(wrapf(cell, period) * 1.37 + s);
    return clamp(prof * hgt * 0.8 + 0.2 * (0.5 + 0.5 * gnoise1(x * 0.5, period * 0.5, s + 9.1)), 0.0, 1.0);
}

// A pine forest on gentle land: narrow tiered spires.
FN float ridgeForest(float x, float period, float s) {
    float land = ridgeHills(x * 0.5, period * 0.5, s) * 0.42;
    float dens = 6.0;
    float u = x * dens;
    float pu = period * dens;
    float ci = floor(u);
    float best = 0.0;
    for (int j = -1; j <= 1; j++) {
        float c = ci + float(j);
        float wc = wrapf(c, pu);
        float h = hash11(wc * 1.37 + s * 1.3);
        float center = c + 0.5 + (hash11(wc * 1.37 + s * 2.7) - 0.5) * 0.8;
        float halfw = 0.38 + 0.22 * hash11(wc * 1.37 + s * 4.1);
        float d = abs(u - center) / halfw;
        float tri = max(0.0, 1.0 - d);
        float tiers = tri - 0.13 * fract(tri * 5.0 + h * 2.0) * (1.0 - tri * 0.7);
        float gap = step(0.12, h);                                // now and then a gap in the trees
        best = max(best, gap * (0.55 + 0.45 * h) * max(0.0, tiers));
    }
    return clamp(land + best * 0.62, 0.0, 1.0);
}

// The top of a sea of cloud: overlapping round puffs, big and small. The height is in noise units,
// so that divided by the frequency the puffs stay round on the cover.
FN float ridgeCloudSea(float x, float period, float s) {
    float best = 0.0;
    for (int band = 0; band < 2; band++) {
        float scale = band == 0 ? 1.0 : 2.5;
        float u = x * scale;
        float pu = period * scale;
        float ci = floor(u);
        for (int j = -1; j <= 1; j++) {
            float c = ci + float(j);
            float wc = wrapf(c, pu);
            float r = 0.55 + 0.35 * hash11(wc * 1.37 + s + float(band) * 9.0);
            float cx = c + 0.5 + (hash11(wc * 1.37 + s * 3.1 + float(band)) - 0.5) * 0.5;
            float base = (band == 0 ? 0.0 : 0.25) + 0.25 * hash11(wc * 2.11 + s);
            float dx = u - cx;
            float dome = sqrt(max(0.0, r * r - dx * dx));
            best = max(best, (base + dome) / scale);
        }
    }
    return clamp(best * 0.85, 0.0, 1.0);
}

// Rolling land with woods on it: patches of round crowns crowded into a billowing treeline.
FN float ridgeGrove(float x, float period, float s) {
    float land = ridgeHills(x * 0.5, period * 0.5, s) * 0.5;
    float patchy = smoothstep(0.42, 0.6, 0.5 + 0.5 * gnoise1(x * 0.75, period * 0.75, s + 12.0));
    float dens = 7.0;
    float u = x * dens;
    float pu = period * dens;
    float ci = floor(u);
    float crowns = 0.0;
    for (int j = -1; j <= 1; j++) {
        float c = ci + float(j);
        float wc = wrapf(c, pu);
        float r = 0.55 + 0.35 * hash11(wc * 1.37 + s * 2.3);
        float cx = c + 0.5 + (hash11(wc * 1.37 + s * 3.7) - 0.5) * 0.6;
        float lift = 0.25 * hash11(wc * 2.9 + s);
        float dx = u - cx;
        crowns = max(crowns, lift + sqrt(max(0.0, r * r - dx * dx)));
    }
    return clamp(land + patchy * (0.12 + crowns * 0.16), 0.0, 1.0);
}

// Headlands and sea stacks: flat tops on steep sides.
FN float ridgeCliffs(float x, float period, float s) {
    float n = 0.5 + 0.5 * gnoise1(x, period, s);
    float top = smoothstep(0.40, 0.52, n);
    float detail = 0.5 + 0.5 * gnoise1(x * 4.0, period * 4.0, s + 2.2);
    float tufts = 0.5 + 0.5 * gnoise1(x * 16.0, period * 16.0, s + 5.2);
    return clamp(top * (0.8 + 0.14 * detail + 0.06 * tufts) + 0.04 * detail, 0.0, 1.0);
}

FN float ridge(float style, float x, float period, float s, float z) {
    if (style < 0.5) return ridgeMountain(x, period, s, 3.0 + z * 3.0);
    if (style < 1.5) return ridgeHills(x, period, s);
    if (style < 2.5) return ridgeDunes(x, period, s);
    if (style < 3.5) return ridgeForest(x, period, s);
    if (style < 4.5) return ridgeCloudSea(x, period, s);
    if (style < 5.5) return ridgeCliffs(x, period, s);
    return ridgeGrove(x, period, s);
}

// How much the sun (or moon) lights the haze at p.
FN float sunLight(Land L, float2 p) {
    float r = length(p - L.sunPos);
    return exp(-r / 0.34) * (1.0 - L.isMoon * 0.6);
}

// ---- sky ----

FN float3 skyColor(Land L, float2 p) {
    float hy = clamp(p.y / L.horizonY, 0.0, 1.3);
    float3 c = mix(L.zenith, L.upper, smoothstep(0.0, 0.72, hy));
    c = mix(c, L.horizon, smoothstep(0.4, 1.06, hy));
    float2 d = p - L.sunPos;
    float r = length(d);
    // the low sky brightens under the sun
    float az = exp(-abs(p.x - L.sunPos.x) * 1.8);
    c = mix(c, mix(L.horizon, L.sunColor, 0.55), smoothstep(0.5, 1.05, hy) * az * 0.4 * (1.0 - L.isMoon));

    // stars, fading towards the horizon, and a faint band of the Milky Way
    if (L.stars > 0.01) {
        float2 g = p * 46.0;
        float2 cell = floor(g);
        float2 rnd = hash22(cell + L.seed);
        float2 at = (cell + 0.15 + 0.7 * rnd) / 46.0;
        float bright = pow(hash12(cell * 1.71 + L.seed), 9.0);
        float k = 900.0 + floor(rnd.y * 2400.0);
        float tw = 0.65 + 0.35 * sin(TAU * (k * L.phase + rnd.x));
        float sr = length(p - at);
        float star = bright * tw * (exp(-sr * sr / 0.0000025) + 0.25 * exp(-sr * sr / 0.00003));
        float faint = 0.35 * pow(hash12(cell * 2.31 + 7.0), 18.0) * exp(-sr * sr / 0.0000012);
        float band = exp(-sq((p.y - L.horizonY * 0.2 - (p.x - 0.5) * 0.55) / 0.13));
        float mw = band * (0.5 + 0.9 * fbm2(float2(p.x * 3.0 + 1.0, p.y * 3.0), 64.0, L.seed + 70.0, 4));
        float fadeH = 1.0 - smoothstep(L.horizonY * 0.35, L.horizonY * 0.95, p.y);
        c += (float3(1.0, 0.97, 0.92) * (star * 1.6 + faint) + float3(0.55, 0.6, 0.8) * mw * 0.06) * L.stars * fadeH;
    }

    // aurora curtains
    if (L.aurora > 0.01) {
        float o1 = fract(L.phase * 7.0) * XP, o2 = fract(L.phase * 3.0) * XP;
        float o3 = fract(L.phase * 2.0) * XP, o4 = fract(L.phase * 5.0) * XP;
        float base = L.horizonY * 0.62 + 0.07 * gnoise1((p.x + o1) * 1.5, XP * 1.5, L.seed + 5.0)
                   + 0.03 * gnoise1((p.x - o2) * 4.0, XP * 4.0, L.seed + 8.0);
        float h = base - p.y;
        float rays = 0.5 + 0.5 * gnoise1((p.x + o3) * 26.0, XP * 26.0, L.seed + 11.0);
        float fold = 0.6 + 0.4 * gnoise1((p.x - o4) * 3.0, XP * 3.0, L.seed + 14.0);
        float I = smoothstep(-0.012, 0.012, h) * exp(-max(h, 0.0) / (0.10 + 0.08 * fold)) * (0.35 + 0.65 * rays * rays) * fold;
        float3 ac = mix(L.auroraA, L.auroraB, smoothstep(0.0, 0.22, h));
        c += ac * I * L.aurora;
    }

    // glow, then the disc
    float gl = L.sunGlow * (0.42 * exp(-r / 0.30) + 0.55 * exp(-r * r / 0.0045)) * (1.0 - L.isMoon * 0.55);
    c = mix(c, max(c, mix(L.sunColor, float3(1.0), 0.25)), clamp(gl, 0.0, 1.0));
    if (L.sunSize > 0.0) {
        float disc = smoothstep(L.sunSize, L.sunSize * 0.86, r);
        if (L.isMoon > 0.5) {
            float2 q = d / L.sunSize;
            float side = q.x * L.moonSide;
            float edge = (1.0 - 2.0 * L.moonK) * sqrt(max(0.0, 1.0 - q.y * q.y));
            float lit = smoothstep(edge - 0.06, edge + 0.06, side);
            float maria = 0.84 + 0.16 * smoothstep(-0.2, 0.3, gnoise2(q * 2.6 + 4.0, 64.0, 3.0));
            float3 moonLit = float3(0.97, 0.96, 0.92) * maria;
            float3 moonDark = mix(c, L.zenith, 0.4) + float3(0.025, 0.03, 0.045);
            c = mix(c, mix(moonDark, moonLit, lit), disc);
            c += float3(0.8, 0.85, 1.0) * 0.12 * L.moonK * exp(-max(r - L.sunSize, 0.0) / 0.03);
        } else {
            float3 sd = mix(L.sunColor, float3(1.0), 0.55);
            c = mix(c, max(c, sd), disc);
            c += L.sunColor * 0.22 * exp(-max(r - L.sunSize, 0.0) / 0.025);
        }
    }

    // clouds: long soft banks, lit from the sun
    if (L.clouds > 0.01) {
        float off = fract(L.phase * 4.0) * XP;
        float2 cp = float2((p.x + off) * 1.5, p.y * 5.0);
        float n = 0.5 + 0.9 * fbm2(cp, XP * 1.5, L.seed + 21.0, 5);
        float band = exp(-sq((p.y - L.cloudY) / 0.2));
        float cov = smoothstep(1.0 - L.clouds, 1.28 - L.clouds, n * band) * (1.0 - smoothstep(L.horizonY * 0.85, L.horizonY, p.y));
        float toward = exp(-r / 0.3);
        float3 cc = mix(L.cloudShade, L.cloudLit, clamp(0.3 + 0.5 * toward + 0.4 * (n - 0.5), 0.0, 1.0));
        cc += L.sunColor * (cov * (1.0 - cov) * 4.0) * exp(-r / 0.18) * 0.5 * (1.0 - L.isMoon * 0.5);
        c = mix(c, cc, cov * 0.9);
    }
    return c;
}

// ---- one ridge, and the mist in front of it ----

// How much mist drifts in front of ridge i at p, thickest along the ridge's foot.
FN float mistIn(Land L, float2 p, int i, int n, float hoverClear) {
    float4 ly = L.layer[i];
    float top = ly.x - ly.y * 0.8;
    if ((i == n - 1 && L.waterY <= 0.0) || p.y <= top) return 0.0;
    float z = n > 1 ? float(i) / float(n - 1) : 1.0;
    float s = L.seed + float(i) * 31.7;
    float moff = fract(L.phase * (3.0 + float(i) * 2.0)) * XP;
    float foot = min(ly.x, L.waterY > 0.0 ? max(L.waterY, top + 0.05) : ly.x) + 0.02;
    float band = smoothstep(top, foot, p.y) * (1.0 - 0.3 * smoothstep(foot, foot + 0.15, p.y));
    float2 mp = float2((p.x + moff) * (13.0 / 6.0), p.y * 9.0 + float(i) * 3.1);
    float warp = fbm2(mp + float2(0.0, 5.2), 13.0, s + 3.0, 3);
    float wisps = 0.5 + 0.9 * fbm2(mp + float2(warp * 1.6, 0.0), 13.0, s + 9.0, 4);
    return clamp(band * wisps, 0.0, 1.0) * L.mistAmount * mix(0.8, 0.38, z) * (1.0 - hoverClear * 0.85);
}

// Ridge i at p: its colour, and how much of p it covers.
FN float4 ridgeAt(Land L, float2 p, int i, int n, float sl, float3 mistCol) {
    float4 ly = L.layer[i];
    bool clouds = ly.w > 3.5 && ly.w < 4.5;
    if (p.y < (clouds ? ly.x - 1.0 / ly.z : ly.x - ly.y) - 0.01 - L.px * 3.0) return float4(0.0);   // above its highest peak
    float z = n > 1 ? float(i) / float(n - 1) : 1.0;              // 0 farthest, 1 nearest
    float k = floor(1.0 + z * 5.0);                                // the nearest crosses a cover in about two minutes
    float off = fract(L.phase * k) * XP;
    float period = XP * ly.z;
    float s = L.seed + float(i) * 31.7;
    float u = (p.x + off) * ly.z;
    float hgt = ridge(ly.w, u, period, s, z);
    float ry = clouds ? ly.x - hgt / ly.z : ly.x - ly.y * hgt;
    float d = p.y - ry;
    float soft = clouds ? max(L.px * 2.0, 0.004) : L.px * (1.1 + (1.0 - z) * 1.6);
    float cov = smoothstep(-soft, soft, d);
    if (cov <= 0.0) return float4(0.0);

    // aerial perspective: far ridges are nearly the colour of the air
    float3 col = mix(mix(L.horizon, L.far, 0.72), L.near, pow(z, 1.3));
    col = mix(col, L.haze + L.sunColor * 0.2, sl * (1.0 - z) * 0.38);
    if (clouds) {
        float lit = exp(-max(d, 0.0) / 0.035);
        col = mix(mix(L.cloudShade, L.mist, 0.35), L.cloudLit + L.sunColor * 0.12 * sl, lit);
    } else if ((ly.w < 2.5 || ly.w > 5.5) && d < 0.16) {
        // faces turned to the sun catch the light, the others fall into shade
        float e = 0.012 * ly.z;
        float slope = (ridge(ly.w, u + e, period, s, z) - ridge(ly.w, u - e, period, s, z)) * ly.y / (2.0 * e / ly.z);
        float dir = L.sunPos.x > p.x ? 1.0 : -1.0;
        float facet = clamp(slope * dir * 1.4, -1.0, 1.0) * exp(-max(d, 0.0) / (ly.w < 0.5 ? 0.06 : 0.05));
        float amount = mix(0.10, 0.22, z) * (L.isMoon > 0.5 ? 0.5 : 1.0) * (ly.w > 1.5 && ly.w < 2.5 ? 1.6 : (ly.w > 0.5 ? 0.7 : 1.0));
        col = mix(col, facet > 0.0 ? mix(col, L.sunColor, 0.5) : col * 0.72, abs(facet) * amount * 2.0);
    }
    // snow on the high peaks
    if (ly.w < 0.5 && L.snowAmount > 0.0) {
        float brk = 0.5 + 0.5 * gnoise1(u * 40.0, period * 40.0, s + 3.0);
        float snow = smoothstep(0.48, 0.66, hgt) * (1.0 - smoothstep(0.0, 0.02 + 0.06 * hgt * brk, d));
        col = mix(col, mix(L.snow, L.haze, (1.0 - z) * 0.5), snow * L.snowAmount);
    }
    // a rim of light along the edge, strongest under the sun
    float back = exp(-abs(p.x - L.sunPos.x) * 2.0) * (L.sunSize > 0.0 ? 1.0 : 0.4);
    col += L.sunColor * L.rim * back * exp(-max(d, 0.0) / (0.0025 + 0.004 * z)) * (1.0 - 0.5 * z);
    // grain of rock and trees on the near ridges
    if (z > 0.3) col *= 1.0 + 0.045 * z * gnoise2(float2(u * 70.0 / ly.z, p.y * 110.0), period * 70.0 / ly.z, s + 6.0);
    // the foot of each ridge sinks into the mist
    float sink = smoothstep(0.0, mix(0.06, 0.2, z) * (0.6 + 0.4 * ly.y / 0.3), d);
    col = mix(col, mistCol, sink * L.mistAmount * mix(0.85, 0.32, z));
    return float4(col, cov);
}

// Layers standing in front of the water (their foot below the far shore) are drawn over it.
FN bool inFront(Land L, int i) { return L.waterY > 0.0 && L.layer[i].x > L.waterY + 0.03; }

// ---- the scene: the ridges from near to far, each with its mist, then the sky behind ----
// Drawn front to back, so a point well inside a near ridge never works out the far ones or the sky.
// Returns the colour, and how much mist lies over the point (for the light rays).

FN float4 scene(Land L, float2 p, bool front) {
    int n = int(L.count + 0.5);
    float hoverClear = L.hoverS * exp(-dot(p - L.hover, p - L.hover) / 0.012);
    float sl = sunLight(L, p);
    float3 mistCol = L.mist + L.sunColor * 0.18 * sl;
    float3 C = float3(0.0);
    float T = 1.0, mistAcc = 0.0;
    for (int j = 0; j < 6; j++) {
        int i = n - 1 - j;
        if (i < 0) break;
        if (!front && inFront(L, i)) continue;
        float m = mistIn(L, p, i, n, hoverClear);
        C += mistCol * (T * m);
        T *= 1.0 - m;
        mistAcc = max(mistAcc, m);
        float4 r = ridgeAt(L, p, i, n, sl, mistCol);
        C += r.rgb * (T * r.a);
        T *= 1.0 - r.a;
        if (T < 0.003) break;
    }
    if (T >= 0.003) C += skyColor(L, p) * T;
    return float4(C, mistAcc);
}

FN float segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

// ---- birds, snow, petals, fireflies ----

FN float3 particles(Land L, float2 p, float3 c) {
    float kind = L.particleKind;
    if (kind < 0.5) return c;
    if (kind < 1.5) {                                                      // a loose flock of birds
        for (int j = 0; j < 5; j++) {
            float fj = float(j);
            float rx = hash11(fj * 3.1 + L.seed);
            float ry = hash11(fj * 5.3 + L.seed);
            float x = fract(L.phase * 36.0 + rx * 0.18) * 1.5 - 0.25;
            float y = L.horizonY * (0.3 + 0.22 * ry) + 0.008 * sin(TAU * (L.phase * 160.0 + rx));
            float sz = 0.007 + 0.004 * hash11(fj * 7.7 + L.seed);
            float flap = sin(TAU * (L.phase * 6400.0 + rx * 3.0));
            float2 b = float2(x + fj * 0.03 * (ry - 0.5), y);
            float2 tipL = b + float2(-sz, -sz * (0.1 + 0.5 * flap));
            float2 tipR = b + float2(sz, -sz * (0.1 + 0.5 * flap));
            float dd = min(segDist(p, b, tipL), segDist(p, b, tipR));
            float a = smoothstep(L.px * 1.3, L.px * 0.3, dd - sz * 0.05);
            c = mix(c, L.particle, a * 0.8);
        }
        return c;
    }
    if (kind < 3.5) {                                                      // snow (2) or petals (3)
        float petals = kind > 2.5 ? 1.0 : 0.0;
        for (int j = 0; j < 3; j++) {
            float fj = float(j);
            float cell = petals > 0.5 ? mix(0.16, 0.09, fj / 2.0) : mix(0.085, 0.045, fj / 2.0);
            float rows = floor(L.units / cell) + 1.0;
            float fall = fract(L.phase * (petals > 0.5 ? 9.0 + fj * 4.0 : 14.0 + fj * 6.0));
            float2 g = float2(p.x / cell, p.y / cell - fall * rows);
            float2 ci = floor(g);
            float2 wc = float2(ci.x, wrapf(ci.y, rows));
            float2 rnd = hash22(wc + L.seed + fj * 9.0);
            float sway = 0.3 * sin(TAU * (L.phase * (40.0 + fj * 13.0) + rnd.x));
            float2 at = ci + float2(0.2 + 0.6 * rnd.x + sway, 0.2 + 0.6 * rnd.y);
            float2 q = g - at;
            float present = step(petals > 0.5 ? 0.62 : 0.6, hash12(wc * 1.3 + L.seed));
            float rad = (petals > 0.5 ? 0.075 : 0.05) + 0.045 * rnd.y;
            if (petals > 0.5) {
                float ang = TAU * (L.phase * 90.0 + rnd.y);
                float cs = cos(ang), sn = sin(ang);
                q = float2(q.x * cs - q.y * sn, q.x * sn + q.y * cs) * float2(1.0, 2.2);
            }
            float a = smoothstep(rad, rad * 0.35, length(q)) * present * mix(0.45, 0.9, fj / 2.0);
            c = mix(c, L.particle * (0.9 + 0.2 * rnd.x), a);
        }
        return c;
    }
    for (int j = 0; j < 9; j++) {                                          // fireflies
        float fj = float(j);
        float rx = hash11(fj * 2.3 + L.seed), ry = hash11(fj * 4.9 + L.seed);
        float2 at = float2(rx, mix(L.horizonY + 0.15, L.units - 0.12, ry))
                  + 0.03 * float2(sin(TAU * (L.phase * 23.0 + rx)), cos(TAU * (L.phase * 17.0 + ry)));
        float blink = pow(0.5 + 0.5 * sin(TAU * (L.phase * 1100.0 + rx * 5.0)), 3.0);
        float dd = length(p - at);
        c += L.particle * blink * (exp(-dd * dd / 0.000012) * 0.9 + exp(-dd * dd / 0.0004) * 0.25);
    }
    return c;
}

// ---- one pixel of the cover ----

// Light rays through the mist, falling from the sun.
FN float3 raysAt(Land L, float2 q, float mist) {
    if (L.rays <= 0.0 || L.sunSize <= 0.0 || L.isMoon > 0.5) return float3(0.0);
    float2 d = q - L.sunPos;
    float ang = atan2(d.y, d.x);
    float ray = pow(0.5 + 0.5 * sin(ang * 23.0 + 1.7 * sin(ang * 9.0 + TAU * L.phase * 3.0)), 3.0)
              * (0.6 + 0.4 * sin(ang * 7.0 - TAU * L.phase * 2.0));
    float I = L.rays * ray * smoothstep(0.0, 0.12, d.y) * exp(-length(d) / 0.55) * (0.25 + 0.75 * mist);
    return L.sunColor * I * 0.3;
}

FN float3 landscape(Land L, float2 p, float2 pixel) {
    float3 c;
    if (L.waterY > 0.0 && p.y > L.waterY) {
        float dy = p.y - L.waterY;
        float depth = dy / (L.units - L.waterY);
        float Z = 0.08 / (dy + 0.004);                                  // distance across the water
        float X = (p.x - 0.5) * Z;
        float w1 = fract(L.phase * 11.0) * 48.0, w2 = fract(L.phase * 17.0) * 120.0;
        float rip = gnoise2(float2(X * 2.0 + w1, Z * 0.9), 48.0, L.seed + 40.0)
                  + 0.5 * gnoise2(float2(X * 5.0 - w2, Z * 2.3), 120.0, L.seed + 44.0);
        if (L.hoverS > 0.0 && L.hover.y > L.waterY) {                  // rings spreading from the pointer
            float hr = length((p - L.hover) * float2(1.0, 2.6));
            rip += L.hoverS * 0.9 * sin(hr * 140.0 - TAU * L.phase * 3000.0) * exp(-hr * 14.0);
        }
        float dx = rip * 0.012 * min(1.0, dy * 10.0 + 0.15);
        float2 q = float2(p.x + dx, L.waterY - dy + rip * 0.004);

        // the near shore first; the water only where it shows through
        int n = int(L.count + 0.5);
        float hoverClear = L.hoverS * exp(-dot(p - L.hover, p - L.hover) / 0.012);
        float sl = sunLight(L, p);
        float3 mistCol = L.mist + L.sunColor * 0.18 * sl;
        float3 C = float3(0.0);
        float T = 1.0;
        for (int j = 0; j < 6; j++) {
            int i = n - 1 - j;
            if (i < 0 || !inFront(L, i)) break;
            float m = mistIn(L, p, i, n, hoverClear);
            C += mistCol * (T * m);
            T *= 1.0 - m;
            float4 r = ridgeAt(L, p, i, n, sl, mistCol);
            C += r.rgb * (T * r.a);
            T *= 1.0 - r.a;
            if (T < 0.003) break;
        }
        if (T >= 0.003) {
            float4 sc = scene(L, q, false);
            float3 w = sc.rgb + raysAt(L, q, sc.a);
            // calm streaks hold the sky more clearly
            float calm = smoothstep(0.55, 0.85, 0.5 + gnoise2(float2(X * 0.6, Z * 5.0), 64.0, L.seed + 47.0));
            float refl = mix(0.86, 0.6, depth) + 0.08 * calm;
            w = mix(L.water, w, refl);
            w *= mix(1.0, 0.86, depth);
            // the glitter path under the sun or moon
            float g1 = fract(L.phase * 13.0) * 120.0;
            float sp = 0.5 + gnoise2(float2(X * 14.0 + g1, Z * 6.0), 120.0, L.seed + 50.0);
            float path = exp(-sq((p.x + dx - L.sunPos.x) / (0.035 + 0.16 * depth)));
            float vis = L.sunSize > 0.0 ? 1.0 : 0.0;
            w += L.sunColor * smoothstep(0.62, 0.92, sp) * path * vis * (L.isMoon > 0.5 ? 0.5 : 0.85);
            // a thin line of light along the far shore, and mist lying on the water
            w += L.horizon * 0.10 * exp(-dy / 0.004);
            w = mix(w, L.mist, exp(-sq(dy / 0.05)) * L.mistAmount * 0.45);
            C += w * T;
        }
        c = C;
    } else {
        float4 sc = scene(L, p, true);
        c = sc.rgb + raysAt(L, p, sc.a);
    }

    c = particles(L, p, c);

    // the pointer warms the air around it a little
    c += L.mist * 0.10 * L.hoverS * exp(-dot(p - L.hover, p - L.hover) / 0.01);

    // a breath of haze over everything, a soft vignette, and grain so the gradients never band
    c = mix(c, L.haze, 0.05);
    float2 v = (p - float2(0.5, L.units * 0.5)) / float2(0.78, L.units * 0.62);
    c *= 1.0 - 0.14 * pow(clamp(dot(v, v), 0.0, 1.5), 1.3);
    c += (hash12(pixel + fract(L.phase * 977.0) * 311.0) - 0.5) * (2.2 / 255.0);
    return clamp(c, float3(0.0), float3(1.0));
}

struct LandUniforms {
    float4 p[25];
    float2 size;            // points
    float scale;            // pixels per point
    float pad;
};

static inline Land unpackLand(constant LandUniforms &U) {
    Land L;
    L.zenith = U.p[0].xyz;
    L.night = U.p[0].w;
    L.upper = U.p[1].xyz;
    L.moonK = U.p[1].w;
    L.horizon = U.p[2].xyz;
    L.horizonY = U.p[2].w;
    L.sunColor = U.p[3].xyz;
    L.sunSize = U.p[3].w;
    L.sunPos = U.p[4].xy;
    L.sunGlow = U.p[4].z;
    L.isMoon = U.p[4].w;
    L.haze = U.p[5].xyz;
    L.mistAmount = U.p[5].w;
    L.mist = U.p[6].xyz;
    L.rays = U.p[6].w;
    L.far = U.p[7].xyz;
    L.rim = U.p[7].w;
    L.near = U.p[8].xyz;
    L.count = U.p[8].w;
    L.cloudLit = U.p[9].xyz;
    L.clouds = U.p[9].w;
    L.cloudShade = U.p[10].xyz;
    L.cloudY = U.p[10].w;
    L.auroraA = U.p[11].xyz;
    L.aurora = U.p[11].w;
    L.auroraB = U.p[12].xyz;
    L.stars = U.p[12].w;
    L.water = U.p[13].xyz;
    L.waterY = U.p[13].w;
    L.snow = U.p[14].xyz;
    L.snowAmount = U.p[14].w;
    L.particle = U.p[15].xyz;
    L.particleKind = U.p[15].w;
    L.hover = U.p[22].xy;
    L.hoverS = U.p[22].z;
    L.phase = U.p[22].w;
    L.px = U.p[23].x;
    L.seed = U.p[23].y;
    L.units = U.p[23].z;
    L.moonSide = U.p[23].w;
    L.layer[0] = U.p[16];
    L.layer[1] = U.p[17];
    L.layer[2] = U.p[18];
    L.layer[3] = U.p[19];
    L.layer[4] = U.p[20];
    L.layer[5] = U.p[21];
    L.extra = U.p[24];
    return L;
}

struct LandOut {
    float4 position [[position]];
    float2 pos;             // points from the top left
};

vertex LandOut landscape_vertex(uint vid [[vertex_id]], constant LandUniforms &U [[buffer(1)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    LandOut o;
    o.pos = corner * U.size;
    o.position = float4(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0);
    return o;
}

fragment float4 landscape_fragment(LandOut in [[stage_in]], constant LandUniforms &U [[buffer(1)]]) {
    Land L = unpackLand(U);
    float2 p = in.pos / U.size.x;
    return float4(landscape(L, p, in.pos * U.scale), 1.0);
}
"""
}
