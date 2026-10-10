/* Folio — full-text search with case, accent, quote, dash and ligature folding.
 *
 * Each block is folded into a comparison form while keeping, for every folded
 * byte, the byte range of the original character it came from. Matches found
 * in the folded text map straight back to exact highlight ranges.
 */
#include "rd_internal.h"
#include <stdlib.h>
#include <string.h>

/* U+00C0–U+00FF → base letters (NULL = keep as is) */
static const char *const LATIN1[64] = {
    "a","a","a","a","a","a","ae","c","e","e","e","e","i","i","i","i",
    "d","n","o","o","o","o","o",NULL,"o","u","u","u","u","y","th","ss",
    "a","a","a","a","a","a","ae","c","e","e","e","e","i","i","i","i",
    "d","n","o","o","o","o","o",NULL,"o","u","u","u","u","y","th","y"};

/* U+0100–U+017F → base letters */
static const char LATIN_EXT_A[129] =
    "aaaaaacccccccc" "dddd" "eeeeeeeeee" "gggggggg" "hhhh" "iiiiiiiiii" "ii" "jj" "kkk"
    "llllllllll" "nnnnnnnnn" "oooooo" "oo" "rrrrrr" "ssssssss" "tttttt" "uuuuuuuuuuuu"
    "ww" "yyy" "zzzzzz" "s";

typedef struct {
    sbuf f;                 /* folded bytes                              */
    uint32_t *m0, *m1;      /* original [start, end) for each folded byte */
    size_t cap;
} folded;

static void fold_push(folded *F, const char *s, size_t n, uint32_t o0, uint32_t o1) {
    for (size_t i = 0; i < n; i++) {
        if (F->f.len >= F->cap) {
            F->cap = F->cap ? F->cap * 2 : 1024;
            F->m0 = realloc(F->m0, sizeof *F->m0 * F->cap);
            F->m1 = realloc(F->m1, sizeof *F->m1 * F->cap);
        }
        F->m0[F->f.len] = o0;
        F->m1[F->f.len] = o1;
        sb_putc(&F->f, s[i]);
    }
}

/* Fold one code point into out (returns bytes written, 0 = drop). */
static size_t fold_cp(uint32_t cp, int exact, char *out) {
    /* punctuation and spacing normalise in both modes */
    switch (cp) {
    case '\t': case '\n': case '\r': case 0xA0: case 0x2002: case 0x2003: case 0x2009: case 0x202F:
        out[0] = ' '; return 1;
    case 0xAD: case 0x200B: case 0x200C: case 0x200D: case 0xFEFF: return 0;
    case 0x2018: case 0x2019: case 0x201B: case 0x2032: case 0x02BC: out[0] = '\''; return 1;
    case 0x201C: case 0x201D: case 0x201E: case 0x2033: case 0xAB: case 0xBB: out[0] = '"'; return 1;
    case 0x2010: case 0x2011: case 0x2012: case 0x2013: case 0x2014: case 0x2015: case 0x2212: out[0] = '-'; return 1;
    case 0x2026: memcpy(out, "...", 3); return 3;
    case 0xFB00: memcpy(out, "ff", 2); return 2;
    case 0xFB01: memcpy(out, "fi", 2); return 2;
    case 0xFB02: memcpy(out, "fl", 2); return 2;
    case 0xFB03: memcpy(out, "ffi", 3); return 3;
    case 0xFB04: memcpy(out, "ffl", 3); return 3;
    }
    if (!exact) {
        if (cp >= 'A' && cp <= 'Z') { out[0] = (char)(cp + 32); return 1; }
        if (cp >= 0x300 && cp <= 0x36F) return 0;                 /* combining accents */
        if (cp >= 0xC0 && cp <= 0xFF && LATIN1[cp - 0xC0]) {
            size_t l = strlen(LATIN1[cp - 0xC0]); memcpy(out, LATIN1[cp - 0xC0], l); return l;
        }
        if (cp >= 0x100 && cp <= 0x17F) { out[0] = LATIN_EXT_A[cp - 0x100]; return 1; }
        switch (cp) {                                               /* Greek tonos, Cyrillic yo */
        case 0x386: case 0x3AC: cp = 0x3B1; break;
        case 0x388: case 0x3AD: cp = 0x3B5; break;
        case 0x389: case 0x3AE: cp = 0x3B7; break;
        case 0x38A: case 0x3AF: case 0x3CA: case 0x390: case 0x3AA: cp = 0x3B9; break;
        case 0x38C: case 0x3CC: cp = 0x3BF; break;
        case 0x38E: case 0x3CD: case 0x3CB: case 0x3B0: case 0x3AB: cp = 0x3C5; break;
        case 0x38F: case 0x3CE: cp = 0x3C9; break;
        case 0x401: case 0x451: cp = 0x435; break;
        }
        if (cp >= 0x391 && cp <= 0x3A9 && cp != 0x3A2) cp += 0x20;  /* Greek */
        else if (cp == 0x3C2) cp = 0x3C3;                           /* final sigma */
        else if (cp >= 0x410 && cp <= 0x42F) cp += 0x20;            /* Cyrillic */
        else if (cp >= 0x400 && cp <= 0x40F) cp += 0x50;
    }
    sbuf tmp = {0};
    sb_utf8(&tmp, cp);
    size_t l = tmp.len;
    memcpy(out, tmp.data, l);
    sb_free(&tmp);
    return l;
}

static void fold_text(folded *F, const char *s, size_t n, int exact) {
    sb_clear(&F->f);
    char out[8];
    size_t i = 0;
    int last_space = 1;
    while (i < n) {
        size_t adv;
        uint32_t cp = utf8_decode((const unsigned char *)s + i, n - i, &adv);
        size_t l = fold_cp(cp, exact, out);
        if (l == 1 && out[0] == ' ') {                 /* collapse runs of spacing */
            if (!last_space) fold_push(F, " ", 1, (uint32_t)i, (uint32_t)(i + adv));
            last_space = 1;
        } else if (l) {
            fold_push(F, out, l, (uint32_t)i, (uint32_t)(i + adv));
            last_space = 0;
        }
        i += adv;
    }
}

static int word_byte(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80;
}

static long find_from(const char *h, size_t hn, const char *nd, size_t nn, size_t from, int whole) {
    if (nn == 0 || nn > hn) return -1;
    for (size_t i = from; i + nn <= hn;) {
        const char *p = memchr(h + i, nd[0], hn - nn - i + 1);
        if (!p) return -1;
        i = (size_t)(p - h);
        if (memcmp(p, nd, nn) == 0) {
            int ok = 1;
            if (whole) {
                if (i > 0 && word_byte((unsigned char)h[i - 1]) && word_byte((unsigned char)nd[0])) ok = 0;
                if (i + nn < hn && word_byte((unsigned char)h[i + nn]) && word_byte((unsigned char)nd[nn - 1])) ok = 0;
                /* don't start in the middle of a UTF-8 sequence */
            }
            if (((unsigned char)h[i] & 0xC0) == 0x80) ok = 0;
            if (ok) return (long)i;
        }
        i++;
    }
    return -1;
}

int32_t rd_search(const rd_book *b, const char *query, int32_t flags, rd_hit *out, int32_t max) {
    if (!query || !out || max <= 0) return 0;
    int exact = (flags & RD_SEARCH_MATCH_CASE) != 0;
    int whole = (flags & RD_SEARCH_WHOLE_WORD) != 0;
    int all = (flags & RD_SEARCH_ALL_WORDS) != 0;

    folded Q = {0};
    fold_text(&Q, query, strlen(query), exact);
    size_t qn = Q.f.len;
    while (qn && Q.f.data[qn - 1] == ' ') qn--;
    if (qn == 0) { sb_free(&Q.f); free(Q.m0); free(Q.m1); return 0; }
    char *q = xstrndup(Q.f.data, qn);
    sb_free(&Q.f); free(Q.m0); free(Q.m1);

    /* terms */
    const char *terms[32]; size_t tl[32]; int nt = 0;
    if (all) {
        char *p = q;
        while (*p && nt < 32) {
            while (*p == ' ') p++;
            if (!*p) break;
            char *e = strchr(p, ' ');
            size_t l = e ? (size_t)(e - p) : strlen(p);
            terms[nt] = p; tl[nt] = l; nt++;
            p += l;
        }
    } else { terms[0] = q; tl[0] = qn; nt = 1; }

    folded F = {0};
    int32_t n = 0;
    for (int ch = 0; ch < b->nch && n < max; ch++) {
        const chapter *c = b->ch[ch];
        for (int k = 0; k < c->nblocks && n < max; k++) {
            const rd_block *blk = &c->blocks[k];
            if (blk->type == RD_IMG || blk->type == RD_HR || blk->text_len == 0) continue;
            fold_text(&F, blk->text, blk->text_len, exact);
            if (F.f.len == 0) continue;
            if (nt > 1) {
                int every = 1;
                for (int t = 0; t < nt && every; t++)
                    if (find_from(F.f.data, F.f.len, terms[t], tl[t], 0, whole) < 0) every = 0;
                if (!every) continue;
            }
            for (int t = 0; t < nt && n < max; t++) {
                size_t from = 0; long at;
                while (n < max && (at = find_from(F.f.data, F.f.len, terms[t], tl[t], from, whole)) >= 0) {
                    size_t fe = (size_t)at + tl[t] - 1;
                    uint32_t o0 = F.m0[at], o1 = F.m1[fe];
                    out[n++] = (rd_hit){ch, k, o0, o1 > o0 ? o1 - o0 : 0};
                    from = (size_t)at + tl[t];
                }
            }
        }
    }
    sb_free(&F.f); free(F.m0); free(F.m1); free(q);
    return n;
}
