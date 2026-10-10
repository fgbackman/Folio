/* Folio — minimal in-memory ZIP reader (stored + deflate) for EPUB containers. */
#include "rd_internal.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <zlib.h>

static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

int zip_open_mem(zarchive *z, const unsigned char *buf, size_t len) {
    memset(z, 0, sizeof *z);
    z->buf = buf; z->len = len;
    if (len < 22) return -1;

    /* End of central directory: last 22 bytes + up to 64K of comment. */
    size_t lo = len > 22 + 65535 ? len - 22 - 65535 : 0, eocd = (size_t)-1;
    for (size_t i = len - 22;; i--) {
        if (rd32(buf + i) == 0x06054b50) { eocd = i; break; }
        if (i == lo) break;
    }
    if (eocd == (size_t)-1) return -1;

    uint16_t count = rd16(buf + eocd + 10);
    uint32_t cdoff = rd32(buf + eocd + 16);
    if (cdoff >= len) return -1;

    z->e = calloc(count ? count : 1, sizeof(zentry));
    size_t p = cdoff;
    for (int i = 0; i < count; i++) {
        if (p + 46 > len || rd32(buf + p) != 0x02014b50) break;
        uint16_t nlen = rd16(buf + p + 28), elen = rd16(buf + p + 30), clen = rd16(buf + p + 32);
        if (p + 46 + nlen > len) break;
        zentry *e = &z->e[z->n++];
        e->method = rd16(buf + p + 10);
        e->csize = rd32(buf + p + 20);
        e->usize = rd32(buf + p + 24);
        e->local_off = rd32(buf + p + 42);
        e->name = xstrndup((const char *)buf + p + 46, nlen);
        p += 46 + (size_t)nlen + elen + clen;
    }
    return z->n > 0 ? 0 : -1;
}

void zip_close(zarchive *z) {
    for (int i = 0; i < z->n; i++) free(z->e[i].name);
    free(z->e);
    memset(z, 0, sizeof *z);
}

int zip_find(const zarchive *z, const char *name) {
    if (!name) return -1;
    while (*name == '/') name++;
    for (int i = 0; i < z->n; i++) if (strcmp(z->e[i].name, name) == 0) return i;
    for (int i = 0; i < z->n; i++) if (strcasecmp(z->e[i].name, name) == 0) return i;
    return -1;
}

unsigned char *zip_extract(const zarchive *z, int idx, size_t *outlen) {
    if (idx < 0 || idx >= z->n) return NULL;
    const zentry *e = &z->e[idx];
    size_t lo = e->local_off;
    if (lo + 30 > z->len || rd32(z->buf + lo) != 0x04034b50) return NULL;
    size_t data = lo + 30 + rd16(z->buf + lo + 26) + rd16(z->buf + lo + 28);
    if (data > z->len || e->csize > z->len - data) return NULL;
    if (e->usize > 512u * 1024 * 1024) return NULL;

    unsigned char *out = malloc((size_t)e->usize + 1);
    if (!out) return NULL;
    size_t n = 0;
    if (e->method == 0) {
        n = e->csize < e->usize ? e->csize : e->usize;
        memcpy(out, z->buf + data, n);
    } else if (e->method == 8) {
        z_stream s;
        memset(&s, 0, sizeof s);
        if (inflateInit2(&s, -MAX_WBITS) != Z_OK) { free(out); return NULL; }
        s.next_in = (Bytef *)(z->buf + data);
        s.avail_in = e->csize;
        s.next_out = out;
        s.avail_out = e->usize;
        int r = inflate(&s, Z_FINISH);
        n = s.total_out;
        inflateEnd(&s);
        if (r != Z_STREAM_END && n == 0 && e->usize != 0) { free(out); return NULL; }
    } else {
        free(out);
        return NULL;
    }
    out[n] = 0;
    if (outlen) *outlen = n;
    return out;
}
