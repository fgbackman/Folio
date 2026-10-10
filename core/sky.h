/*
 * Folio sky engine — real skies for the book covers.
 *
 * Every cover shows a real constellation (HYG star catalogue, d3-celestial figures and
 * Milky Way outline), pre-projected onto a cover 1 unit wide and 1.5 units tall, with
 * north up and east to the left. The functions below place things that move — the Sun,
 * Moon and planets, meteor-shower activity, eclipses — at their real positions for any date.
 */
#ifndef FOLIO_SKY_H
#define FOLIO_SKY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Deep-sky object kinds (sky_dso.kind) */
#define SKY_EMISSION   1   /* glowing hydrogen cloud            */
#define SKY_PILLARS    2   /* Eagle Nebula, Pillars of Creation */
#define SKY_TRIFID     3   /* red + blue nebula cut by dust     */
#define SKY_ROSETTE    4   /* hollow emission ring              */
#define SKY_REFLECTION 5   /* blue dust lit by stars            */
#define SKY_PN_RING    6   /* planetary nebula ring / shells    */
#define SKY_PN_BIPOLAR 7   /* hourglass planetary nebula        */
#define SKY_SNR        8   /* supernova remnant                 */
#define SKY_GALAXY     9
#define SKY_CLUSTER    10
#define SKY_DARK       11  /* dark nebula                       */
#define SKY_BLACKHOLE  12  /* EHT-style photon ring             */
#define SKY_PULSAR     13
#define SKY_ECHO       14  /* light echo                        */
#define SKY_COMPLEX    15  /* multicoloured cloud complex       */

typedef struct { float x, y, mag, bv, dist; int16_t name, desc; uint8_t line, variable; } sky_star;
typedef struct { uint16_t a, b; } sky_seg;
typedef struct {
    const char *name, *detail;
    uint8_t kind, variant;
    float x, y, size, ratio, angle, period;
} sky_dso;
typedef struct { uint32_t start; uint16_t count; uint8_t level, poly; } sky_ring;

typedef struct {
    const char *abbr, *name;
    double ra0, dec0, s, ox, oy;                 /* projection: cover = (ox, oy) - s * stereo(ra, dec) */
    const sky_star *stars; int32_t nstars;
    const sky_seg *segs; int32_t nsegs;          /* constellation figure, in drawing order */
    const sky_dso *dsos; int32_t ndsos;
    const float *mw; const sky_ring *rings; int32_t nrings;   /* Milky Way outline, 5 brightness levels */
    const float *ecl; int32_t necl;              /* ecliptic, x/y pairs, NAN pair = break */
    int8_t shower[3];                            /* meteor showers radiating here, -1 = none */
    int8_t aurora;                               /* 1 aurora borealis, -1 australis, 0 none */
    int8_t flare;                                /* historic supernova / nova replay, -1 = none */
    int16_t pole;                                /* star the sky wheels around (Polaris), -1 = none */
    const char *facts;                           /* '\n'-separated captions */
    const char *lens;                            /* gravitational-lens caption, "" = default */
} sky_constellation;

typedef struct {
    const char *name, *parent;
    double ra, dec;                               /* radiant, degrees */
    int16_t speed, zhr;                           /* km/s, zenithal hourly rate at peak */
    int8_t m0, d0, mp, dp, m1, d1;                /* activity window and peak (month, day) */
    float sigma;                                  /* width of the peak, days */
} sky_shower;

/* kind: 0 total solar, 1 annular, 2 hybrid, 3 partial solar, 4 total lunar, 5 partial lunar, 6 penumbral */
typedef struct { int16_t year; int8_t month, day, kind; int16_t duration; const char *title; } sky_eclipse;
/* kind: 0 total solar, 1 annular, 2 total lunar, 3 partial lunar; corona: 0 solar minimum, 1 middle, 2 maximum */
typedef struct { int8_t kind, corona; const char *title, *detail; } sky_replay;
typedef struct { const char *title, *detail; float ion, dust, curve; int8_t green, anti, striae, horns; } sky_comet;
/* kind: 0 supernova, 1 nova, 2 great eruption, 3 light echo */
typedef struct { double ra, dec; const char *title, *detail; float mag; int8_t kind; } sky_flare;
typedef struct { const char *name; double e, varpi; const char *period; float r, g, b; int8_t retrograde; } sky_body;

extern const sky_constellation sky_constellations[]; extern const int32_t sky_nconstellations;
extern const char *const sky_names[];               extern const int32_t sky_nnames;
extern const sky_shower sky_showers[];             extern const int32_t sky_nshowers;
extern const sky_eclipse sky_calendar[];           extern const int32_t sky_ncalendar;
extern const sky_replay sky_replays[];             extern const int32_t sky_nreplays;
extern const sky_comet sky_comets[];               extern const int32_t sky_ncomets;
extern const sky_flare sky_flares[];               extern const int32_t sky_nflares;
extern const sky_body sky_bodies[];                extern const int32_t sky_nbodies;

/* Accessors (use these from Swift rather than the arrays). */
int32_t sky_constellation_count(void);
const sky_constellation *sky_constellation_at(int32_t i);
const char *sky_name(int32_t i);
int32_t sky_shower_count(void);
const sky_shower *sky_shower_at(int32_t i);
int32_t sky_replay_count(void);
const sky_replay *sky_replay_at(int32_t i);
int32_t sky_comet_count(void);
const sky_comet *sky_comet_at(int32_t i);
int32_t sky_flare_count(void);
const sky_flare *sky_flare_at(int32_t i);
int32_t sky_body_count(void);
const sky_body *sky_body_at(int32_t i);

/* Julian Day from Unix seconds. */
double sky_jd(double unix_seconds);

/* Project RA/Dec (degrees, J2000) onto a constellation's cover. Returns 0 if behind the sky. */
int32_t sky_project(const sky_constellation *c, double ra, double dec, double *x, double *y);

/* Sun: apparent geocentric RA/Dec and ecliptic longitude, degrees. */
void sky_sun(double jd, double *ra, double *dec, double *lon);

/* Moon: RA/Dec (degrees), illuminated fraction 0..1, elongation 0..360 (waxing below 180). */
void sky_moon(double jd, double *ra, double *dec, double *illum, double *elongation);

/* Next time (JD) after jd when the Moon's elongation reaches target (0 new, 90, 180 full, 270). */
double sky_moon_next(double jd, double target);

/* Planets 0 Mercury, 1 Venus, 2 Mars, 3 Jupiter, 4 Saturn, 5 Uranus, 6 Neptune. */
int32_t sky_planet(int32_t planet, double jd, double *ra, double *dec, double *mag);
const char *sky_planet_name(int32_t planet);
/* Angular distance between two points, degrees. */
double sky_separation(double ra1, double dec1, double ra2, double dec2);
void sky_planet_rgb(int32_t planet, float *r, float *g, float *b);

/* Current zenithal hourly rate of a shower (0 outside its activity window). */
float sky_shower_zhr(const sky_shower *s, double jd);

/* The real eclipse on this UT date, or NULL. */
const sky_eclipse *sky_eclipse_on(double jd);

/* Kepler's equation: position in the orbit plane for semi-major axis 1, Sun at the origin,
   perihelion along +x, mean anomaly M in radians. */
void sky_kepler(double e, double M, double *x, double *y);

/* Colour of a star from its B–V index, as sRGB 0..1. */
void sky_bv_rgb(float bv, float *r, float *g, float *b);

#ifdef __cplusplus
}
#endif
#endif
