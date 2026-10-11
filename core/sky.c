/* Folio sky engine — positions of the Sun, Moon and planets, meteor-shower activity,
 * the eclipse calendar and Kepler orbits.
 *
 * Planets: JPL "Approximate Positions of the Planets", Keplerian elements valid 1800–2050
 * (E. M. Standish). Moon: low-precision series from the Astronomical Almanac (about 0.3°).
 */
#include "sky.h"
#include <math.h>
#include <stddef.h>
#include <time.h>

#define D2R (M_PI / 180.0)
#define R2D (180.0 / M_PI)
static const double OBLIQUITY = 23.43928 * D2R;

static double norm360(double a) { a = fmod(a, 360.0); return a < 0 ? a + 360.0 : a; }
static double norm180(double a) { a = norm360(a); return a > 180.0 ? a - 360.0 : a; }

double sky_jd(double unix_seconds) { return unix_seconds / 86400.0 + 2440587.5; }

/* ------------------------------------------------------------------ projection */

int32_t sky_project(const sky_constellation *c, double ra, double dec, double *x, double *y) {
    double a = (ra - c->ra0) * D2R, d = dec * D2R, d0 = c->dec0 * D2R;
    double cosc = sin(d0) * sin(d) + cos(d0) * cos(d) * cos(a);
    if (cosc < -0.5) { *x = *y = -10; return 0; }
    double k = 2.0 / (1.0 + cosc);
    double X = k * cos(d) * sin(a);
    double Y = k * (cos(d0) * sin(d) - sin(d0) * cos(d) * cos(a));
    *x = c->ox - c->s * X;
    *y = c->oy - c->s * Y;
    return cosc > 0.0;
}

/* ------------------------------------------------------------------ planets */

/* a, e, I, L, long.peri, long.node; then rates per Julian century */
static const double ELEMENTS[8][12] = {
    {0.38709927, 0.20563593, 7.00497902, 252.25032350, 77.45779628, 48.33076593,
     0.00000037, 0.00001906, -0.00594749, 149472.67411175, 0.16047689, -0.12534081},
    {0.72333566, 0.00677672, 3.39467605, 181.97909950, 131.60246718, 76.67984255,
     0.00000390, -0.00004107, -0.00078890, 58517.81538729, 0.00268329, -0.27769418},
    {1.00000261, 0.01671123, -0.00001531, 100.46457166, 102.93768193, 0.0,
     0.00000562, -0.00004392, -0.01294668, 35999.37244981, 0.32327364, 0.0},
    {1.52371034, 0.09339410, 1.84969142, -4.55343205, -23.94362959, 49.55953891,
     0.00001847, 0.00007882, -0.00813131, 19140.30268499, 0.44441088, -0.29257343},
    {5.20288700, 0.04838624, 1.30439695, 34.39644051, 14.72847983, 100.47390909,
     -0.00011607, -0.00013253, -0.00183714, 3034.74612775, 0.21252668, 0.20469106},
    {9.53667594, 0.05386179, 2.48599187, 49.95424423, 92.59887831, 113.66242448,
     -0.00125060, -0.00050991, 0.00193609, 1222.49362201, -0.41897216, -0.28867794},
    {19.18916464, 0.04725744, 0.77263783, 313.23810451, 170.95427630, 74.01692503,
     -0.00196176, -0.00004397, -0.00242939, 428.48202785, 0.40805281, 0.04240589},
    {30.06992276, 0.00859048, 1.77004347, -55.12002969, 44.96476227, 131.78422574,
     0.00026291, 0.00005105, 0.00035372, 218.45945325, -0.32241464, -0.00508664},
};
static const double ABS_MAG[8] = {-0.42, -4.40, -3.86, -1.52, -9.40, -8.88, -7.19, -6.87};

static double solve_kepler(double e, double M) {
    double E = (e < 0.8) ? M + e * sin(M) : M_PI;
    for (int i = 0; i < 60; i++) {
        double dE = (E - e * sin(E) - M) / (1.0 - e * cos(E));
        E -= dE;
        if (fabs(dE) < 1e-12) break;
    }
    return E;
}

/* heliocentric ecliptic J2000 coordinates, AU */
static void helio(int body, double jd, double *x, double *y, double *z) {
    const double *el = ELEMENTS[body];
    double T = (jd - 2451545.0) / 36525.0;
    double a = el[0] + el[6] * T, e = el[1] + el[7] * T, I = (el[2] + el[8] * T) * D2R;
    double L = el[3] + el[9] * T, W = el[4] + el[10] * T, N = el[5] + el[11] * T;
    double w = (W - N) * D2R, Om = N * D2R;
    double M = norm180(L - W) * D2R;
    double E = solve_kepler(e, M);
    double xp = a * (cos(E) - e), yp = a * sqrt(1 - e * e) * sin(E);
    *x = (cos(w) * cos(Om) - sin(w) * sin(Om) * cos(I)) * xp + (-sin(w) * cos(Om) - cos(w) * sin(Om) * cos(I)) * yp;
    *y = (cos(w) * sin(Om) + sin(w) * cos(Om) * cos(I)) * xp + (-sin(w) * sin(Om) + cos(w) * cos(Om) * cos(I)) * yp;
    *z = (sin(w) * sin(I)) * xp + (cos(w) * sin(I)) * yp;
}

static void ecl_to_radec(double x, double y, double z, double *ra, double *dec) {
    double ye = y * cos(OBLIQUITY) - z * sin(OBLIQUITY);
    double ze = y * sin(OBLIQUITY) + z * cos(OBLIQUITY);
    *ra = norm360(atan2(ye, x) * R2D);
    *dec = atan2(ze, sqrt(x * x + ye * ye)) * R2D;
}

static const int32_t PLANET_BODY[7] = {0, 1, 3, 4, 5, 6, 7};
static const char *const PLANET_NAMES[7] = {"Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune"};
static const float PLANET_RGB[7][3] = {
    {0.86f, 0.80f, 0.74f}, {1.00f, 0.97f, 0.88f}, {1.00f, 0.62f, 0.42f}, {1.00f, 0.93f, 0.80f},
    {1.00f, 0.88f, 0.62f}, {0.70f, 0.92f, 0.95f}, {0.56f, 0.68f, 1.00f}};

int32_t sky_planet(int32_t planet, double jd, double *ra, double *dec, double *mag) {
    if (planet < 0 || planet > 6) return 0;
    double px, py, pz, ex, ey, ez;
    helio(PLANET_BODY[planet], jd, &px, &py, &pz);
    helio(2, jd, &ex, &ey, &ez);
    double gx = px - ex, gy = py - ey, gz = pz - ez;
    ecl_to_radec(gx, gy, gz, ra, dec);
    double r = sqrt(px * px + py * py + pz * pz), delta = sqrt(gx * gx + gy * gy + gz * gz);
    double R = sqrt(ex * ex + ey * ey + ez * ez);
    if (mag) {
        double m = ABS_MAG[PLANET_BODY[planet]] + 5.0 * log10(r * delta);
        double cosa = (r * r + delta * delta - R * R) / (2 * r * delta);   /* phase angle */
        double lit = (1.0 + cosa) / 2.0;
        if (planet <= 1) m -= 2.5 * log10(lit < 0.02 ? 0.02 : lit);         /* crescent Mercury / Venus */
        static const double brightest[7] = {-2.5, -4.9, -2.9, -2.9, -0.5, 5.3, 7.7};
        *mag = m < brightest[planet] ? brightest[planet] : m;
    }
    return 1;
}

double sky_separation(double ra1, double dec1, double ra2, double dec2) {
    double c = sin(dec1 * D2R) * sin(dec2 * D2R) + cos(dec1 * D2R) * cos(dec2 * D2R) * cos((ra1 - ra2) * D2R);
    return acos(c > 1 ? 1 : c < -1 ? -1 : c) * R2D;
}

const char *sky_planet_name(int32_t planet) { return (planet >= 0 && planet < 7) ? PLANET_NAMES[planet] : ""; }

void sky_planet_rgb(int32_t planet, float *r, float *g, float *b) {
    if (planet < 0 || planet > 6) planet = 0;
    *r = PLANET_RGB[planet][0]; *g = PLANET_RGB[planet][1]; *b = PLANET_RGB[planet][2];
}

void sky_sun(double jd, double *ra, double *dec, double *lon) {
    double ex, ey, ez;
    helio(2, jd, &ex, &ey, &ez);
    ecl_to_radec(-ex, -ey, -ez, ra, dec);
    if (lon) *lon = norm360(atan2(-ey, -ex) * R2D);
}

/* ------------------------------------------------------------------ moon */

static void moon_ecliptic(double jd, double *lam, double *bet) {
    double T = (jd - 2451545.0) / 36525.0;
    double l = 218.32 + 481267.881 * T
        + 6.29 * sin((135.0 + 477198.87 * T) * D2R) - 1.27 * sin((259.3 - 413335.36 * T) * D2R)
        + 0.66 * sin((235.7 + 890534.22 * T) * D2R) + 0.21 * sin((269.9 + 954397.74 * T) * D2R)
        - 0.19 * sin((357.5 + 35999.05 * T) * D2R) - 0.11 * sin((186.5 + 966404.03 * T) * D2R);
    double b = 5.13 * sin((93.3 + 483202.02 * T) * D2R) + 0.28 * sin((228.2 + 960400.89 * T) * D2R)
        - 0.28 * sin((318.3 + 6003.15 * T) * D2R) - 0.17 * sin((217.6 - 407332.21 * T) * D2R);
    *lam = norm360(l);
    *bet = b;
}

static double moon_elongation(double jd) {
    double lam, bet, slon;
    moon_ecliptic(jd, &lam, &bet);
    double sra, sdec;
    sky_sun(jd, &sra, &sdec, &slon);
    return norm360(lam - slon);
}

void sky_moon(double jd, double *ra, double *dec, double *illum, double *elongation) {
    double lam, bet, slon, sra, sdec;
    moon_ecliptic(jd, &lam, &bet);
    sky_sun(jd, &sra, &sdec, &slon);
    double l = lam * D2R, b = bet * D2R;
    double x = cos(b) * cos(l), y = cos(b) * sin(l), z = sin(b);
    if (ra && dec) ecl_to_radec(x, y, z, ra, dec);
    double el = norm360(lam - slon);
    double cosd = cos(b) * cos((lam - slon) * D2R);
    if (illum) *illum = (1.0 - cosd) / 2.0;
    if (elongation) *elongation = el;
}

double sky_moon_next(double jd, double target) {
    /* step until the elongation passes the target, then bisect */
    double prev = norm180(moon_elongation(jd) - target);
    double t = jd;
    for (int i = 0; i < 80; i++) {
        double t2 = t + 0.5;
        double cur = norm180(moon_elongation(t2) - target);
        if (prev < 0 && cur >= 0) {
            double lo = t, hi = t2;
            for (int k = 0; k < 40; k++) {
                double mid = (lo + hi) / 2;
                if (norm180(moon_elongation(mid) - target) < 0) lo = mid; else hi = mid;
            }
            return (lo + hi) / 2;
        }
        prev = cur;
        t = t2;
    }
    return jd + 29.53;
}

/* ------------------------------------------------------------------ calendar helpers */

static void jd_to_date(double jd, int *y, int *m, int *d, double *frac) {
    double z = floor(jd + 0.5), f = jd + 0.5 - z, a = z;
    if (z >= 2299161) {
        double alpha = floor((z - 1867216.25) / 36524.25);
        a = z + 1 + alpha - floor(alpha / 4);
    }
    double b = a + 1524, c = floor((b - 122.1) / 365.25), dd = floor(365.25 * c), e = floor((b - dd) / 30.6001);
    *d = (int)(b - dd - floor(30.6001 * e));
    *m = (int)(e < 14 ? e - 1 : e - 13);
    *y = (int)(*m > 2 ? c - 4716 : c - 4715);
    if (frac) *frac = f;
}

static double day_of_year(int m, int d) {
    static const int start[12] = {0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334};
    return start[(m - 1) % 12] + d;
}

float sky_shower_zhr(const sky_shower *s, double jd) {
    int y, m, d; double frac;
    jd_to_date(jd, &y, &m, &d, &frac);
    double now = day_of_year(m, d) + frac;
    double a = day_of_year(s->m0, s->d0), p = day_of_year(s->mp, s->dp), b = day_of_year(s->m1, s->d1) + 1;
    /* distances on a 365-day circle */
    #define CIRC(x) (fmod(fmod((x), 365.0) + 365.0 + 182.5, 365.0) - 182.5)
    double from_start = CIRC(now - a), to_end = CIRC(b - now), width = CIRC(b - a);
    if (width < 0) width += 365.0;
    if (from_start < 0 || to_end < 0 || from_start > width) return 0.0f;
    double dp = CIRC(now - p);
    #undef CIRC
    double zhr = s->zhr * (exp(-dp * dp / (2.0 * s->sigma * s->sigma)) + 0.06);
    return (float)zhr;
}

const sky_eclipse *sky_eclipse_on(double jd) {
    int y, m, d;
    jd_to_date(jd, &y, &m, &d, NULL);
    for (int32_t i = 0; i < sky_ncalendar; i++)
        if (sky_calendar[i].year == y && sky_calendar[i].month == m && sky_calendar[i].day == d)
            return &sky_calendar[i];
    return NULL;
}

/* ------------------------------------------------------------------ orbits and colour */

void sky_kepler(double e, double M, double *x, double *y) {
    double E = solve_kepler(e, fmod(M, 2 * M_PI));
    *x = cos(E) - e;
    *y = sqrt(1 - e * e) * sin(E);
}

void sky_bv_rgb(float bv, float *r, float *g, float *b) {
    if (bv < -0.4f) bv = -0.4f;
    if (bv > 2.0f) bv = 2.0f;
    /* Ballesteros (2012): B–V → temperature; then a blackbody approximation to sRGB */
    double t = 4600.0 * (1.0 / (0.92 * bv + 1.7) + 1.0 / (0.92 * bv + 0.62)) / 100.0;
    double R, G, B;
    if (t <= 66) { R = 255; G = 99.4708025861 * log(t) - 161.1195681661; }
    else { R = 329.698727446 * pow(t - 60, -0.1332047592); G = 288.1221695283 * pow(t - 60, -0.0755148492); }
    if (t >= 66) B = 255;
    else if (t <= 19) B = 0;
    else B = 138.5177312231 * log(t - 10) - 305.0447927307;
    #define C01(v) ((float)((v) < 0 ? 0 : (v) > 255 ? 1 : (v) / 255.0))
    *r = C01(R); *g = C01(G); *b = C01(B);
    #undef C01
}

/* ------------------------------------------------------------------ accessors for Swift */

/* The skies are the 42 constellations of skydata.c followed by the fields of skydata2.c;
   star names are numbered across both the same way. */
int32_t sky_constellation_count(void) { return sky_nconstellations + sky_nmore; }
const sky_constellation *sky_constellation_at(int32_t i) {
    if (i < 0) return NULL;
    if (i < sky_nconstellations) return &sky_constellations[i];
    i -= sky_nconstellations;
    return i < sky_nmore ? &sky_more[i] : NULL;
}
const char *sky_name(int32_t i) {
    if (i < 0) return "";
    if (i < sky_nnames) return sky_names[i];
    i -= sky_nnames;
    return i < sky_nnames2 ? sky_names2[i] : "";
}
int32_t sky_shower_count(void) { return sky_nshowers; }
const sky_shower *sky_shower_at(int32_t i) { return (i >= 0 && i < sky_nshowers) ? &sky_showers[i] : NULL; }
int32_t sky_replay_count(void) { return sky_nreplays; }
const sky_replay *sky_replay_at(int32_t i) { return (i >= 0 && i < sky_nreplays) ? &sky_replays[i] : NULL; }
int32_t sky_comet_count(void) { return sky_ncomets; }
const sky_comet *sky_comet_at(int32_t i) { return (i >= 0 && i < sky_ncomets) ? &sky_comets[i] : NULL; }
int32_t sky_flare_count(void) { return sky_nflares; }
const sky_flare *sky_flare_at(int32_t i) { return (i >= 0 && i < sky_nflares) ? &sky_flares[i] : NULL; }
int32_t sky_body_count(void) { return sky_nbodies; }
const sky_body *sky_body_at(int32_t i) { return (i >= 0 && i < sky_nbodies) ? &sky_bodies[i] : NULL; }
