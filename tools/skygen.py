#!/usr/bin/env python3
"""Builds core/skydata2.c: the skies added to the 42 constellations of core/skydata.c.

    python3 tools/skygen.py DATA_DIR [COUNT]

DATA_DIR must hold
    hyg.csv                      HYG database v4.1    github.com/astronexus/HYG-Database (hyg/CURRENT/hygdata_v41.csv)
    constellations.lines.json    d3-celestial         github.com/ofrohn/d3-celestial (data/)
    constellations.json, asterisms.json, mw.json, messier.json   (same place)

COUNT is the total number of skies wanted, the 42 included (default 200).

Every field is laid out like the original ones: a cover 1 unit wide and 1.5 tall, north up, east left,
stereographic about the field's centre; stars out to a margin for parallax, brightest 230; the figure's
stars first; the Milky Way clipped to a window around the cover; the ecliptic as a polyline.
"""
import csv, json, math, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from skyfields import CONSTELLATION_FACTS, ASTERISM_FACTS, ASTERISM_NAMES, OBJECTS, PLACES

DATA = sys.argv[1]
TOTAL = int(sys.argv[2]) if len(sys.argv) > 2 else 200
OLD = os.path.join(HERE, "..", "core", "skydata.c")
OUT = os.path.join(HERE, "..", "core", "skydata2.c")

CAP = 1.718873              # cover units per unit of stereographic plane: 1 degree = 0.03 of the cover's width
ZOOM = CAP * 4
D2R = math.pi / 180
STAR_BOX = (-0.12, 1.12, -0.12, 1.61)
MW_BOX = (-0.42, 1.42, -0.42, 1.92)
MAX_STARS = 230

# ---------------------------------------------------------------- geometry

def vec(ra, dec):
    a, d = ra * D2R, dec * D2R
    return (math.cos(d) * math.cos(a), math.cos(d) * math.sin(a), math.sin(d))

def radec(v):
    n = math.sqrt(sum(c * c for c in v))
    return (math.degrees(math.atan2(v[1], v[0])) % 360, math.degrees(math.asin(max(-1, min(1, v[2] / n)))))

def sep(a, b):
    return math.degrees(math.acos(max(-1, min(1, sum(x * y for x, y in zip(vec(*a), vec(*b)))))))

def stereo(ra0, dec0, ra, dec):
    """Stereographic plane about (ra0, dec0); also returns the cosine of the distance from the centre."""
    a, d, d0 = (ra - ra0) * D2R, dec * D2R, dec0 * D2R
    cosc = math.sin(d0) * math.sin(d) + math.cos(d0) * math.cos(d) * math.cos(a)
    k = 2.0 / (1.0 + max(cosc, -0.9995))
    return (k * math.cos(d) * math.sin(a), k * (math.cos(d0) * math.sin(d) - math.sin(d0) * math.cos(d) * math.cos(a)), cosc)

class Frame:
    def __init__(self, ra0, dec0, s, ox, oy):
        self.ra0, self.dec0, self.s, self.ox, self.oy = ra0, dec0, s, ox, oy

    def project(self, ra, dec):
        X, Y, cosc = stereo(self.ra0, self.dec0, ra, dec)
        return (self.ox - self.s * X, self.oy - self.s * Y, cosc)

    def unproject(self, x, y):
        X, Y = (self.ox - x) / self.s, (self.oy - y) / self.s
        rho = math.hypot(X, Y)
        if rho < 1e-12:
            return (self.ra0, self.dec0)
        c = 2 * math.atan(rho / 2)
        d0 = self.dec0 * D2R
        dec = math.asin(math.cos(c) * math.sin(d0) + Y * math.sin(c) * math.cos(d0) / rho)
        ra = self.ra0 * D2R + math.atan2(X * math.sin(c), rho * math.cos(d0) * math.cos(c) - Y * math.sin(d0) * math.sin(c))
        return (math.degrees(ra) % 360, math.degrees(dec))

def inside(p, box):
    return box[0] <= p[0] <= box[1] and box[2] <= p[1] <= box[3]

# ---------------------------------------------------------------- the original 42

old = open(OLD, encoding="utf-8").read()
NAMES = json.loads("[" + re.search(r"sky_names\[\] = \{(.*?)\};\n", old, re.S).group(1) + "]")
OLD_NAMES = len(NAMES)
name_index = {n: i for i, n in enumerate(NAMES)}

def name_id(text):
    if not text:
        return -1
    if text not in name_index:
        name_index[text] = len(NAMES)
        NAMES.append(text)
    return name_index[text]

table = old[old.index("const sky_constellation sky_constellations[]"):old.index("const int32_t sky_nconstellations")]
OLD_FIELDS = []
for m in re.finditer(r'\{"(\w+)", "([^"]+)", ([-\d.]+), ([-\d.]+), ([-\d.]+), ([-\d.]+), ([-\d.]+),\n.*?\n\s+\{[^}]*\}, -?\d+, -?\d+, -?\d+, "((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)"\}', table):
    abbr, name, ra0, dec0, s, ox, oy, facts, lens = m.groups()
    OLD_FIELDS.append(dict(abbr=abbr, name=name, frame=Frame(float(ra0), float(dec0), float(s), float(ox), float(oy)),
                           facts=facts.replace("\\'", "'").split("\\n")))
assert len(OLD_FIELDS) == 42, len(OLD_FIELDS)

# Their hand-made deep-sky objects, back on the sky so that any new field can show them too.
HANDMADE = []
for f in OLD_FIELDS:
    m = re.search(r"static const sky_dso DS_%s\[\] = \{\n(.*?)\n\};" % f["abbr"].lower(), old, re.S)
    if not m:
        continue
    for row in re.finditer(r'\{"([^"]*)", "([^"]*)", (\d+), (\d+), ([-\d.]+)f, ([-\d.]+)f, ([-\d.]+)f, ([-\d.]+)f, ([-\d.]+)f, ([-\d.]+)f\}', m.group(1)):
        name, detail, kind, variant, x, y, size, ratio, angle, period = row.groups()
        ra, dec = f["frame"].unproject(float(x), float(y))
        if any(h["name"] == name for h in HANDMADE):
            continue
        fact = next((t for t in f["facts"] if t.split(" — ")[0] in (name, name.split(" · ")[0], name.split(" · ")[-1])), None)
        HANDMADE.append(dict(name=name, kind=int(kind), variant=int(variant), ra=ra, dec=dec, angular=float(size) / f["frame"].s,
                             ratio=float(ratio), angle=float(angle), period=float(period), fact=fact, rank=0))

def table_of(name, pattern):
    body = old[old.index("const %s[]" % name):]
    body = body[:body.index("};")]
    return [(float(a), float(b)) for a, b in re.findall(pattern, body)]

SHOWERS = table_of("sky_shower sky_showers", r'\{"[^"]*", "[^"]*", ([-\d.]+), ([-\d.]+),')
FLARES = table_of("sky_flare sky_flares", r"\{([-\d.]+), ([-\d.]+), \"")

# ---------------------------------------------------------------- catalogues

def spectral(spect):
    s = (spect or "").strip()
    if not s:
        return ""
    if s[0] == "D":
        return "white dwarf"
    colour = {"O": "blue", "B": "blue-white", "A": "white", "F": "yellow-white", "G": "yellow", "K": "orange", "M": "red",
              "C": "carbon", "N": "carbon", "R": "carbon", "S": "red"}.get(s[0].upper())
    if not colour:
        return ""
    lum = re.search(r"(Ia\+?|Iab|Ib|III|II|IV|I|V)", s[1:])
    kind = {"Ia": "supergiant", "Ia+": "supergiant", "Iab": "supergiant", "Ib": "supergiant", "I": "supergiant", "II": "bright giant",
            "III": "giant", "IV": "subgiant", "V": "main-sequence star"}.get(lum.group(1) if lum else "", "star")
    return colour + " " + kind

STARS = []
with open(os.path.join(DATA, "hyg.csv"), newline="", encoding="utf-8") as fh:
    for row in csv.DictReader(fh):
        if row["id"] == "0" or not row["mag"]:
            continue
        mag = float(row["mag"])
        if mag > 9.6:
            continue
        dist = float(row["dist"] or 0)
        STARS.append(dict(ra=float(row["ra"]) * 15, dec=float(row["dec"]), mag=mag, bv=float(row["ci"] or 0.6),
                          ly=dist * 3.26156 if 0 < dist < 90000 else 0.0, name=row["proper"], desc=spectral(row["spect"]),
                          con=row["con"], bayer=row["bayer"]))
for st in STARS:
    st["v"] = vec(st["ra"], st["dec"])
    st["variable"] = {"Algol": 1, "Mira": 2, "Betelgeuse": 4}.get(st["name"], 3 if (st["con"], st["bayer"]) == ("Cep", "Del") else 0)
BRIGHT = [s for s in STARS if s["mag"] < 8.2]
BY_NAME = {s["name"]: s for s in STARS if s["name"]}

def nearest_star(ra, dec, within):
    v = vec(ra, dec)
    limit = math.cos(within * D2R)
    best, score = None, None
    for s in BRIGHT:
        dot = v[0] * s["v"][0] + v[1] * s["v"][1] + v[2] * s["v"][2]
        if dot < limit:
            continue
        # figures are drawn through naked-eye stars: prefer the bright one over a faint one a hair nearer
        value = math.degrees(math.acos(min(1, dot))) + 0.06 * s["mag"]
        if score is None or value < score:
            best, score = s, value
    return best

def lonlat(points):
    return [((p[0] + 360) % 360, p[1]) for p in points]

CON_NAMES = {f["id"]: f["properties"]["name"] for f in json.load(open(os.path.join(DATA, "constellations.json")))["features"]}
CON_LINES = {}
for f in json.load(open(os.path.join(DATA, "constellations.lines.json")))["features"]:
    CON_LINES.setdefault(f["id"], []).extend(lonlat(l) for l in f["geometry"]["coordinates"])     # Serpens comes in two parts

ASTERISMS = {}
for f in json.load(open(os.path.join(DATA, "asterisms.json")))["features"]:
    a = ASTERISMS.setdefault(f["id"], dict(name=f["properties"]["n"].strip("'"), lines=[]))
    a["lines"] += [lonlat(l) for l in f["geometry"]["coordinates"]]

MESSIER = {}
for f in json.load(open(os.path.join(DATA, "messier.json")))["features"]:
    p = f["properties"]
    dims = [float(x) for x in re.findall(r"[\d.]+", str(p.get("dim", "")))] or [6.0]
    MESSIER[p["name"]] = dict(ra=f["geometry"]["coordinates"][0] % 360, dec=f["geometry"]["coordinates"][1], type=p["type"],
                              alt=p.get("alt", "").replace("´", "'").replace("’", "'"), mag=float(p["mag"] or 9), dims=dims)

# Milky Way outline: one even-odd polygon of many rings at each of five brightness levels.
MW = []
for level, f in enumerate(json.load(open(os.path.join(DATA, "mw.json")))["features"]):
    for poly in f["geometry"]["coordinates"]:
        for ring in poly:
            MW.append((level, [((p[0] + 360) % 360, p[1]) for p in ring]))
MW_VEC = [(level, [vec(*p) for p in ring]) for level, ring in MW]

def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])

def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

def arcs_cross(a, b, c, d):
    """Do the great-circle arcs a-b and c-d (each shorter than half a turn) cross?"""
    n1, n2 = cross(a, b), cross(c, d)
    if (dot(n2, a) > 0) == (dot(n2, b) > 0) or (dot(n1, c) > 0) == (dot(n1, d) > 0):
        return False
    t = cross(n1, n2)
    for p in (t, (-t[0], -t[1], -t[2])):
        if dot(cross(a, p), n1) >= 0 and dot(cross(p, b), n1) >= 0 and dot(cross(c, p), n2) >= 0 and dot(cross(p, d), n2) >= 0:
            return True
    return False

OUTSIDE = vec(192.86, 27.13)      # the galactic north pole, as far from the Milky Way as the sky gets

def in_milky_way(level, v):
    """Even-odd test on the sphere: count the outline crossings on the way in from the galactic pole."""
    mid = tuple(a + b for a, b in zip(OUTSIDE, v))
    n = math.sqrt(dot(mid, mid))
    if n < 1e-6:
        mid, n = (0.0, 0.0, 1.0), 1.0
    mid = tuple(c / n for c in mid)
    crossings = 0
    for lv, ring in MW_VEC:
        if lv != level:
            continue
        for i in range(len(ring)):
            c, d = ring[i], ring[(i + 1) % len(ring)]
            crossings += arcs_cross(OUTSIDE, mid, c, d) + arcs_cross(mid, v, c, d)
    return crossings % 2 == 1

def clip(points, box):
    """Sutherland–Hodgman against the window."""
    x0, x1, y0, y1 = box
    edges = [(lambda p: p[0] >= x0, lambda a, b: (x0, a[1] + (b[1] - a[1]) * (x0 - a[0]) / (b[0] - a[0]))),
             (lambda p: p[0] <= x1, lambda a, b: (x1, a[1] + (b[1] - a[1]) * (x1 - a[0]) / (b[0] - a[0]))),
             (lambda p: p[1] >= y0, lambda a, b: (a[0] + (b[0] - a[0]) * (y0 - a[1]) / (b[1] - a[1]), y0)),
             (lambda p: p[1] <= y1, lambda a, b: (a[0] + (b[0] - a[0]) * (y1 - a[1]) / (b[1] - a[1]), y1))]
    out = points
    for keep, cut in edges:
        src, out = out, []
        for i in range(len(src)):
            a, b = src[i - 1], src[i]
            if keep(b):
                if not keep(a):
                    out.append(cut(a, b))
                out.append(b)
            elif keep(a):
                out.append(cut(a, b))
        if not out:
            return []
    return out

def thin(points, step=0.004):
    out = [points[0]]
    for p in points[1:]:
        if abs(p[0] - out[-1][0]) > step or abs(p[1] - out[-1][1]) > step:
            out.append(p)
    return out

def milky_way(frame):
    rings = []                          # (level, points)
    far = vec((frame.ra0 + 180) % 360, -frame.dec0)
    for level in range(5):
        found = []
        for lv, ring in MW:
            if lv != level:
                continue
            pts = [frame.project(*p) for p in ring]
            if max(p[2] for p in pts) < -0.2:
                continue
            cut = clip([(p[0], p[1]) for p in pts], MW_BOX)
            if len(cut) >= 3:
                cut = thin(cut)
                if len(cut) >= 3:
                    found.append(cut)
        # In the flat picture "outside every ring" means the far side of the sky. If that is in the
        # Milky Way, the whole window is, and the rings are holes in it.
        if in_milky_way(level, far):
            x0, x1, y0, y1 = MW_BOX
            found.insert(0, [(x1, y0), (x0, y0), (x0, y1), (x1, y1)])
        rings += [(level, r) for r in found]
    return rings

OBLIQUITY = 23.4392911 * D2R

def ecliptic(frame):
    out, run = [], False
    for i in range(0, 721):
        lon = i * 0.5 * D2R
        ra = math.degrees(math.atan2(math.sin(lon) * math.cos(OBLIQUITY), math.cos(lon))) % 360
        dec = math.degrees(math.asin(math.sin(lon) * math.sin(OBLIQUITY)))
        x, y, cosc = frame.project(ra, dec)
        if cosc > 0 and inside((x, y), (-0.32, 1.32, -0.32, 1.82)):
            out.append((x, y))
            run = True
        elif run:
            out.append(None)
            run = False
    while out and out[-1] is None:
        out.pop()
    return out

# ---------------------------------------------------------------- deep-sky objects

GENERIC = {"gc": (10, 1), "oc": (10, 0), "sfr": (1, 1), "en": (1, 1), "bn": (1, 1), "rn": (5, 0), "pn": (6, 0), "snr": (8, 1),
           "s": (9, 0), "e": (9, 0), "i": (9, 6)}
WORDS = {"gc": "globular cluster", "oc": "open cluster", "sfr": "nebula", "rn": "reflection nebula", "pn": "planetary nebula",
         "snr": "supernova remnant", "s": "spiral galaxy", "e": "elliptical galaxy", "i": "irregular galaxy"}

def place(spec):
    """An object's position: a Messier number, a star's name, or (ra, dec) in degrees."""
    if isinstance(spec, str):
        if spec in MESSIER:
            return (MESSIER[spec]["ra"], MESSIER[spec]["dec"])
        return (BY_NAME[spec]["ra"], BY_NAME[spec]["dec"])
    return spec

EXTRA = []
for o in OBJECTS:
    ra, dec = place(o["at"])
    EXTRA.append(dict(name=o["name"], kind=o["kind"], variant=o.get("variant", 0), ra=ra, dec=dec,
                      angular=3 * o["arcmin"] / 60 * D2R, ratio=o.get("ratio", 1.0), angle=o.get("angle", -90) * D2R,
                      period=0.0, fact=o.get("fact"), rank=1))
taken = [h for h in HANDMADE + EXTRA]
for key, m in MESSIER.items():
    if m["type"] not in GENERIC:
        continue
    if any(re.search(r"\b%s\b" % key, t["name"]) or sep((t["ra"], t["dec"]), (m["ra"], m["dec"])) < 0.25 for t in taken):
        continue
    kind, variant = GENERIC[m["type"]]
    ratio = 1.0
    if kind == 9:
        ratio = max(0.25, min(1.0, m["dims"][-1] / m["dims"][0])) if len(m["dims"]) > 1 else (0.9 if m["type"] == "e" else 0.7)
    label = "%s · %s" % (key, m["alt"]) if m["alt"] and "asterism" not in m["alt"] and "patch" not in m["alt"] else "%s · %s" % (key, WORDS[m["type"]])
    EXTRA.append(dict(name=label, kind=kind, variant=variant, ra=m["ra"], dec=m["dec"], angular=3 * m["dims"][0] / 60 * D2R,
                      ratio=ratio, angle=-math.pi / 2, period=0.0, fact=None, rank=2 + m["mag"] / 20))

# ---------------------------------------------------------------- building a field

def fit(points, cap, centre=None):
    """A frame that puts the points' bounding box in the figure area of the cover."""
    if centre is None:
        total = [sum(c) for c in zip(*[vec(*p) for p in points])]
        centre = radec(total)
    ra0, dec0 = centre
    flat = [stereo(ra0, dec0, *p) for p in points]
    xs, ys = [p[0] for p in flat], [p[1] for p in flat]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    s = min(cap, 0.76 / w if w > 1e-9 else cap, 0.66 / h if h > 1e-9 else cap)
    # east is to the left and north up, so the plane's axes are both flipped on the cover
    return Frame(ra0, dec0, s, 0.5 + s * (max(xs) + min(xs)) / 2, 0.44 + s * (max(ys) + min(ys)) / 2)

def build(name, abbr, frame, lines, facts, centred=False, lens=""):
    limit = min(9.5, 6.6 + 5 * math.log10(max(1.0, frame.s / CAP)))
    centre = vec(frame.ra0, frame.dec0)
    reach = math.cos(min(math.pi, 2 * math.atan(1.3 / frame.s)))     # nothing farther than this can be on the cover

    # the figure
    figure, segs, order = [], [], {}
    def index_of(star):
        if id(star) not in order:
            order[id(star)] = len(figure)
            figure.append(star)
        return order[id(star)]
    for line in lines:
        prev = None
        for p in line:
            star = nearest_star(p[0], p[1], 0.7)
            if star is None:
                prev = None
                continue
            k = index_of(star)
            if prev is not None and prev != k and (prev, k) not in segs and (k, prev) not in segs:
                segs.append((prev, k))
            prev = k

    picked = {id(s) for s in figure}
    field = []
    for s in STARS:
        if id(s) in picked or s["mag"] > limit or dot(centre, s["v"]) < reach:
            continue
        x, y, cosc = frame.project(s["ra"], s["dec"])
        if cosc > 0 and inside((x, y), STAR_BOX):
            field.append(s)
    field.sort(key=lambda s: s["mag"])
    stars = figure + field[:max(0, MAX_STARS - len(figure))]
    rows = []
    for i, s in enumerate(stars):
        x, y, _ = frame.project(s["ra"], s["dec"])
        rows.append((x, y, s["mag"], s["bv"], s["ly"], name_id(s["name"]), name_id(s["desc"]), 1 if i < len(figure) else 0, s["variable"]))

    # deep sky: the hand-made ones first, then the ones defined for the new fields, then plain Messier objects
    dsos = []
    def wanted(o):
        # a field made for an object shows what is nearest its middle; a figure shows the best known
        if centred:
            x, y, _ = frame.project(o["ra"], o["dec"])
            return (0 if o["rank"] < 2 else 1, math.hypot(x - 0.5, y - 0.42))
        return (o["rank"], 0)
    for o in sorted(HANDMADE + EXTRA, key=wanted):
        x, y, cosc = frame.project(o["ra"], o["dec"])
        if cosc <= 0 or not inside((x, y), (0.07, 0.93, 0.08, 0.86)):      # clear of the title below
            continue
        size = max(0.05, min(0.42, o["angular"] * frame.s))
        if any(math.hypot(x - d["x"], y - d["y"]) < 0.05 for d in dsos):
            continue
        dsos.append(dict(o, x=x, y=y, size=size))
        if len(dsos) == 4:
            break

    showers = []
    for i, (ra, dec) in enumerate(SHOWERS):
        x, y, cosc = frame.project(ra, dec)
        if cosc > 0 and inside((x, y), (0.05, 0.95, 0.05, 1.25)) and len(showers) < 3:
            showers.append(i)
    showers += [-1] * (3 - len(showers))
    flare = -1
    for i, (ra, dec) in enumerate(FLARES):
        x, y, cosc = frame.project(ra, dec)
        if cosc > 0 and inside((x, y), (0.08, 0.92, 0.08, 1.2)):
            flare = i
            break
    pole = -1
    if frame.dec0 > 62:
        for i, s in enumerate(stars):
            if s["name"] == "Polaris" and inside(rows[i][:2], (0.1, 0.9, 0.1, 1.3)):
                pole = i
    aurora = 1 if frame.dec0 >= 45 else (-1 if frame.dec0 <= -45 else 0)

    # captions: what was written for this field, what is known of the objects in it, and its brightest named star
    lines_out = list(facts)
    for d in dsos:
        if d["fact"] and d["fact"] not in lines_out and len(lines_out) < 4:
            lines_out.append(d["fact"])
    said = " ".join(lines_out)
    named = [s for i, s in enumerate(stars) if s["name"] and s["ly"] > 0 and s["desc"] and s["name"] not in said
             and inside(rows[i][:2], (0.05, 0.95, 0.05, 1.3))]
    if named and len(lines_out) < 4:
        s = min(named, key=lambda s: s["mag"])
        ly = s["ly"]
        shown = "%.1f" % ly if ly < 20 else "%d" % round(ly) if ly < 100 else "{:,}".format(int(round(ly, -1 if ly < 1000 else -2)))
        lines_out.append("%s — %s %s %s light-years away" % (s["name"], "an" if s["desc"][0] in "aeiou" else "a", s["desc"], shown))
    return dict(name=name, abbr=abbr, frame=frame, stars=rows, segs=segs, dsos=dsos, mw=milky_way(frame), ecl=ecliptic(frame),
                showers=showers, aurora=aurora, flare=flare, pole=pole, facts=lines_out, lens=lens)

def home_constellation(ra, dec):
    star = nearest_star(ra, dec, 12)
    return star["con"] if star and star["con"] else "Ori"

def nearby_figures(frame):
    """Pieces of the constellation figures crossing a field that has no figure of its own."""
    out = []
    for lines in CON_LINES.values():
        for line in lines:
            run = []
            for p in line:
                x, y, cosc = frame.project(*p)
                if cosc > 0 and inside((x, y), (-0.05, 1.05, -0.05, 1.5)):
                    run.append(p)
                else:
                    if len(run) > 1:
                        out.append(run)
                    run = []
            if len(run) > 1:
                out.append(run)
    return out

FIELDS = []

# 1. The constellations not among the first 42. Serpens is two pieces of sky; the tail is already there.
have = {f["abbr"] for f in OLD_FIELDS}
for abbr in sorted(CON_LINES):
    lines = CON_LINES[abbr]
    if abbr == "Ser":
        lines = [l for l in lines if all(p[0] < 255 for p in l)]
        name = "Serpens Caput"
    elif abbr in have:
        continue
    else:
        name = {"Corona Austrina": "Corona Australis"}.get(CON_NAMES[abbr], CON_NAMES[abbr])
    points = [p for l in lines for p in l]
    FIELDS.append(build(name, abbr, fit(points, CAP), lines, CONSTELLATION_FACTS.get(name, [])))

# 2. Asterisms
for key, a in ASTERISMS.items():
    points = [p for l in a["lines"] for p in l]
    span = max(sep(p, q) for p in points for q in points)
    if "-" in key or span > 70 or span < 1.0 or len(points) < 2:       # "UMa-Vir" and the like are star-hopping routes, not figures
        continue
    frame = fit(points, ZOOM)
    name = ASTERISM_NAMES.get(key, a["name"])
    abbr = home_constellation(frame.ra0, frame.dec0)
    facts = ASTERISM_FACTS.get(key) or ["%s — an asterism in %s" % (name, CON_NAMES.get(abbr, abbr))]
    FIELDS.append(build(name, abbr, frame, a["lines"], facts))

# 3. Deep-sky showpieces and notable places, as many as it takes
for p in PLACES:
    if len(OLD_FIELDS) + len(FIELDS) >= TOTAL:
        break
    ra, dec = place(p["at"])
    s = min(ZOOM, 1 / (p["width"] * D2R))
    frame = Frame(ra, dec, s, 0.5, 0.42)
    FIELDS.append(build(p["name"], home_constellation(ra, dec), frame, nearby_figures(frame), p["facts"], centred=True))

print("fields: %d old + %d new = %d" % (len(OLD_FIELDS), len(FIELDS), len(OLD_FIELDS) + len(FIELDS)), file=sys.stderr)

# ---------------------------------------------------------------- C

def cstr(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def f(x):
    return "%.4ff" % x

out = ["/* Generated by tools/skygen.py — do not edit. The skies beyond the first 42: the remaining constellations,\n"
       "   asterisms, and fields around deep-sky objects and notable places. Same sources as skydata.c. */",
       '#include "sky.h"', "#include <math.h>", "#include <stddef.h>", "",
       "/* Star names and descriptions continue the numbering of sky_names. */",
       "const char *const sky_names2[] = {" + ", ".join(cstr(n) for n in NAMES[OLD_NAMES:]) + "};",
       "const int32_t sky_nnames2 = %d;" % (len(NAMES) - OLD_NAMES), ""]
entries = []
for i, fl in enumerate(FIELDS):
    t = "x%03d" % i
    out.append("static const sky_star ST_%s[] = {" % t)
    out += ["  {%s, %s, %s, %s, %s, %d, %d, %d, %d}," % (f(x), f(y), f(mag), f(bv), f(ly), n, d, line, var)
            for x, y, mag, bv, ly, n, d, line, var in fl["stars"]]
    out.append("};")
    if fl["segs"]:
        out.append("static const sky_seg SG_%s[] = {%s};" % (t, ", ".join("{%d, %d}" % s for s in fl["segs"])))
    if fl["dsos"]:
        out.append("static const sky_dso DS_%s[] = {" % t)
        out += ['  {%s, "", %d, %d, %s, %s, %s, %s, %s, %s},' % (cstr(d["name"]), d["kind"], d["variant"], f(d["x"]), f(d["y"]), f(d["size"]),
                                                               f(d["ratio"]), f(d["angle"]), f(d["period"])) for d in fl["dsos"]]
        out.append("};")
    flat, rings, start = [], [], 0
    for level, ring in fl["mw"]:
        flat += ["%s, %s" % (f(x), f(y)) for x, y in ring]
        rings.append("{%d, %d, %d, 0}" % (start, len(ring), level))
        start += len(ring)
    if rings:
        out.append("static const float MW_%s[] = {%s};" % (t, ", ".join(flat)))
        out.append("static const sky_ring MR_%s[] = {%s};" % (t, ", ".join(rings)))
    if fl["ecl"]:
        out.append("static const float EC_%s[] = {%s};" % (t, ", ".join("NAN, NAN" if p is None else "%s, %s" % (f(p[0]), f(p[1])) for p in fl["ecl"])))
    fr = fl["frame"]
    entries.append('  {%s, %s, %.5f, %.5f, %.6f, %.6f, %.6f,\n   ST_%s, %d, %s, %d, %s, %d, %s, %s, %d, %s, %d,\n   {%d, %d, %d}, %d, %d, %d, %s, %s},' % (
        cstr(fl["abbr"]), cstr(fl["name"]), fr.ra0, fr.dec0, fr.s, fr.ox, fr.oy, t, len(fl["stars"]),
        "SG_" + t if fl["segs"] else "NULL", len(fl["segs"]), "DS_" + t if fl["dsos"] else "NULL", len(fl["dsos"]),
        "MW_" + t if rings else "NULL", "MR_" + t if rings else "NULL", len(rings), "EC_" + t if fl["ecl"] else "NULL", len(fl["ecl"]),
        fl["showers"][0], fl["showers"][1], fl["showers"][2], fl["aurora"], fl["flare"], fl["pole"],
        cstr("\n".join(fl["facts"])).replace("\n", "\\n"), cstr(fl["lens"])))
out += ["", "const sky_constellation sky_more[] = {"] + entries + ["};", "const int32_t sky_nmore = %d;" % len(FIELDS), ""]
open(OUT, "w", encoding="utf-8").write("\n".join(out))

for fl in FIELDS:
    print("%-28s %-4s s=%.2f stars=%3d segs=%2d mw=%3d dsos=%s" % (fl["name"], fl["abbr"], fl["frame"].s, len(fl["stars"]), len(fl["segs"]),
                                                              len(fl["mw"]), [d["name"] for d in fl["dsos"]]), file=sys.stderr)
