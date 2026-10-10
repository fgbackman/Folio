/* Folio — small shared helpers: buffers, UTF-8, paths. */
#include "rd_internal.h"
#include <stdlib.h>
#include <string.h>

void sb_reserve(sbuf *b, size_t extra) {
    if (b->len + extra + 1 <= b->cap) return;
    size_t nc = b->cap ? b->cap * 2 : 64;
    while (nc < b->len + extra + 1) nc *= 2;
    char *nd = realloc(b->data, nc);
    if (!nd) abort();
    b->data = nd; b->cap = nc;
}
void sb_putc(sbuf *b, char c) { sb_reserve(b, 1); b->data[b->len++] = c; }
void sb_put(sbuf *b, const char *s, size_t n) {
    if (!n) return;
    sb_reserve(b, n); memcpy(b->data + b->len, s, n); b->len += n;
}
void sb_puts(sbuf *b, const char *s) { sb_put(b, s, strlen(s)); }
void sb_utf8(sbuf *b, uint32_t cp) {
    if (cp < 0x80) sb_putc(b, (char)cp);
    else if (cp < 0x800) { sb_putc(b, (char)(0xC0 | cp >> 6)); sb_putc(b, (char)(0x80 | (cp & 0x3F))); }
    else if (cp < 0x10000) {
        sb_putc(b, (char)(0xE0 | cp >> 12)); sb_putc(b, (char)(0x80 | ((cp >> 6) & 0x3F)));
        sb_putc(b, (char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x110000) {
        sb_putc(b, (char)(0xF0 | cp >> 18)); sb_putc(b, (char)(0x80 | ((cp >> 12) & 0x3F)));
        sb_putc(b, (char)(0x80 | ((cp >> 6) & 0x3F))); sb_putc(b, (char)(0x80 | (cp & 0x3F)));
    }
}
void sb_clear(sbuf *b) { b->len = 0; }
void sb_free(sbuf *b) { free(b->data); b->data = NULL; b->len = b->cap = 0; }
char *sb_cstr(sbuf *b) { sb_reserve(b, 0); b->data[b->len] = 0; return b->data; }

char *xstrdup(const char *s) { return s ? xstrndup(s, strlen(s)) : NULL; }
char *xstrndup(const char *s, size_t n) {
    char *d = malloc(n + 1);
    if (!d) abort();
    memcpy(d, s, n); d[n] = 0; return d;
}

/* Decode one UTF-8 sequence. Invalid bytes decode as themselves (Latin-1). */
uint32_t utf8_decode(const unsigned char *s, size_t n, size_t *adv) {
    unsigned c = s[0];
    if (c < 0x80) { *adv = 1; return c; }
    int len = (c >= 0xF0 && c < 0xF8) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC2 && c < 0xE0) ? 2 : 0;
    if (len == 0 || (size_t)len > n) { *adv = 1; return c; }
    uint32_t cp = c & (0xFF >> (len + 1));
    for (int i = 1; i < len; i++) {
        if ((s[i] & 0xC0) != 0x80) { *adv = 1; return c; }
        cp = cp << 6 | (s[i] & 0x3F);
    }
    *adv = (size_t)len;
    return cp;
}

int utf8_valid(const unsigned char *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        if (s[i] < 0x80) { i++; continue; }
        size_t adv; uint32_t cp = utf8_decode(s + i, n - i, &adv);
        if (adv == 1 && cp >= 0x80) return 0;
        i += adv;
    }
    return 1;
}

char *path_dir(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? xstrndup(path, (size_t)(slash - path + 1)) : xstrdup("");
}

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Join dir + href, drop fragment/query, percent-decode, normalise . and .. */
char *path_resolve(const char *dir, const char *href) {
    size_t hl = strcspn(href, "#?");
    sbuf joined = {0};
    if (href[0] != '/') sb_puts(&joined, dir ? dir : "");
    for (size_t i = (href[0] == '/'); i < hl; i++) {
        int h1, h2;
        if (href[i] == '%' && i + 2 < hl && (h1 = hexval(href[i + 1])) >= 0 && (h2 = hexval(href[i + 2])) >= 0) {
            sb_putc(&joined, (char)(h1 * 16 + h2)); i += 2;
        } else sb_putc(&joined, href[i]);
    }
    sb_cstr(&joined);

    /* normalise segments */
    char **seg = NULL; int nseg = 0, cap = 0;
    char *save = NULL, *tok = strtok_r(joined.data, "/", &save);
    while (tok) {
        if (strcmp(tok, ".") == 0 || tok[0] == 0) { }
        else if (strcmp(tok, "..") == 0) { if (nseg) nseg--; }
        else {
            if (nseg == cap) { cap = cap ? cap * 2 : 8; seg = realloc(seg, sizeof *seg * (size_t)cap); }
            seg[nseg++] = tok;
        }
        tok = strtok_r(NULL, "/", &save);
    }
    sbuf out = {0};
    if (dir && dir[0] == '/') sb_putc(&out, '/');   /* filesystem paths stay absolute */
    for (int i = 0; i < nseg; i++) { if (i) sb_putc(&out, '/'); sb_puts(&out, seg[i]); }
    free(seg); sb_free(&joined);
    char *r = xstrdup(out.data ? sb_cstr(&out) : "");
    sb_free(&out);
    return r;
}
