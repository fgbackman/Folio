/* Folio — book lifecycle and the public accessors. */
#include "rd_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

chapter *book_add_chapter(rd_book *b, const char *path) {
    if (b->nch == b->capch) {
        b->capch = b->capch ? b->capch * 2 : 16;
        b->ch = realloc(b->ch, sizeof *b->ch * (size_t)b->capch);
    }
    chapter *c = calloc(1, sizeof *c);
    c->path = xstrdup(path);
    b->ch[b->nch++] = c;
    return c;
}

void book_add_toc(rd_book *b, const char *title, int ch, int block, int depth, const char *href) {
    if (b->ntoc == b->captoc) {
        b->captoc = b->captoc ? b->captoc * 2 : 32;
        b->toc = realloc(b->toc, sizeof *b->toc * (size_t)b->captoc);
    }
    b->toc[b->ntoc++] = (tocent){xstrdup(title), ch, block, depth > 6 ? 6 : depth, xstrdup(href)};
}

static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long sz = ftell(f);
    if (sz < 0 || sz > 1024L * 1024 * 1024) { fclose(f); return NULL; }
    rewind(f);
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[got] = 0;
    *len = got;
    return buf;
}

static int ends_with(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && strcasecmp(s + a - b, suffix) == 0;
}

static char *short_text(const char *s, size_t max) {
    size_t n = strlen(s);
    if (n <= max) return xstrdup(s);
    size_t cut = max;
    while (cut > max / 2 && s[cut] != ' ') cut--;
    while (cut && ((unsigned char)s[cut] & 0xC0) == 0x80) cut--;   /* utf-8 boundary */
    sbuf o = {0};
    sb_put(&o, s, cut);
    sb_puts(&o, "\xE2\x80\xA6");
    return sb_cstr(&o);
}

/* After loading: chapter titles, and a heading-based TOC when the book has none. */
static void finalize(rd_book *b) {
    for (int i = 0; i < b->nch; i++) {
        chapter *c = b->ch[i];
        for (int t = 0; t < b->ntoc && !c->title; t++)
            if (b->toc[t].chapter == i) c->title = xstrdup(b->toc[t].title);
        for (int k = 0; k < c->nblocks && k < 12 && !c->title; k++)
            if (c->blocks[k].type >= RD_H1 && c->blocks[k].type <= RD_H3) c->title = short_text(c->blocks[k].text, 70);
        if (!c->title) {
            int only_images = c->nblocks > 0;
            for (int k = 0; k < c->nblocks; k++) if (c->blocks[k].type != RD_IMG) only_images = 0;
            char tmp[48];
            if (i == 0 && only_images) snprintf(tmp, sizeof tmp, "Cover");
            else if (i == 0 && b->nch > 1) snprintf(tmp, sizeof tmp, "Opening");
            else if (b->nch == 1 && b->title) { c->title = xstrdup(b->title); continue; }
            else snprintf(tmp, sizeof tmp, "Section %d", i + 1);
            c->title = xstrdup(tmp);
        }
    }
    if (b->ntoc == 0) {
        /* shallowest heading level used decides depth 0 */
        int top = RD_H3 + 1;
        for (int i = 0; i < b->nch; i++)
            for (int k = 0; k < b->ch[i]->nblocks; k++) {
                int t = b->ch[i]->blocks[k].type;
                if (t >= RD_H1 && t <= RD_H3 && t < top) top = t;
            }
        int deepest = top == RD_H3 ? RD_H3 : top + 1;      /* two levels at most */
        for (int i = 0; i < b->nch && b->ntoc < 2000; i++) {
            chapter *c = b->ch[i];
            int added = 0;
            for (int k = 0; k < c->nblocks; k++) {
                int t = c->blocks[k].type;
                if (t < top || t > deepest) continue;
                char *title = short_text(c->blocks[k].text, 70);
                book_add_toc(b, title, i, k, t - top, NULL);
                free(title);
                added = 1;
            }
            if (!added && b->nch > 1) book_add_toc(b, c->title, i, 0, 0, NULL);
        }
    }
}

rd_book *rd_open(const char *path, char *err, size_t errlen) {
    if (err && errlen) err[0] = 0;
    size_t len = 0;
    char *data = read_file(path, &len);
    if (!data) { if (err) snprintf(err, errlen, "Could not read the file."); return NULL; }

    rd_book *b = calloc(1, sizeof *b);
    b->file = (unsigned char *)data;
    b->file_len = len;
    b->dir = path_dir(path);

    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    char *fallback = xstrdup(base);
    char *dot = strrchr(fallback, '.');
    if (dot && dot != fallback) *dot = 0;
    for (char *p = fallback; *p; p++) if (*p == '_') *p = ' ';

    int rc;
    int is_zip = len >= 4 && memcmp(data, "PK\x03\x04", 4) == 0;
    if (is_zip || ends_with(path, ".epub")) { b->kind = BK_EPUB; rc = load_epub(b, err, errlen); }
    else if (ends_with(path, ".md") || ends_with(path, ".markdown")) { b->kind = BK_MARKDOWN; rc = load_text(b, 1, fallback); }
    else if (ends_with(path, ".html") || ends_with(path, ".htm") || ends_with(path, ".xhtml")) { b->kind = BK_HTML; rc = load_html(b, fallback); }
    else { b->kind = BK_TEXT; rc = load_text(b, 0, fallback); }

    if (rc != 0) { free(fallback); rd_close(b); return NULL; }
    if (!b->title) b->title = xstrdup(fallback);
    if (!b->author) b->author = xstrdup("");
    free(fallback);
    if (b->nch == 0) book_add_chapter(b, NULL);
    finalize(b);

    /* EPUB keeps its bytes (resources are read from the zip); others can drop them. */
    if (b->kind != BK_EPUB) { free(b->file); b->file = NULL; b->file_len = 0; }
    return b;
}

void rd_close(rd_book *b) {
    if (!b) return;
    for (int i = 0; i < b->nch; i++) {
        chapter *c = b->ch[i];
        for (int k = 0; k < c->nblocks; k++) { free((void *)c->blocks[k].text); free((void *)c->blocks[k].spans); }
        for (int k = 0; k < c->nanchors; k++) free(c->anchors[k].id);
        free(c->blocks); free(c->anchors); free(c->path); free(c->title); free(c);
    }
    for (int t = 0; t < b->ntoc; t++) { free(b->toc[t].title); free(b->toc[t].href); }
    zip_close(&b->zip);
    free(b->ch); free(b->toc); free(b->title); free(b->author); free(b->cover);
    free(b->dir); free(b->file); free(b);
}

const char *rd_title(const rd_book *b) { return b->title; }
const char *rd_author(const rd_book *b) { return b->author; }
const char *rd_format(const rd_book *b) {
    switch (b->kind) { case BK_EPUB: return "EPUB"; case BK_MARKDOWN: return "Markdown"; case BK_HTML: return "HTML"; default: return "Text"; }
}
uint64_t rd_word_count(const rd_book *b) { return b->words; }
int32_t rd_chapter_count(const rd_book *b) { return b->nch; }

const char *rd_chapter_title(const rd_book *b, int32_t ch) {
    return (ch >= 0 && ch < b->nch) ? b->ch[ch]->title : "";
}
uint32_t rd_chapter_text_len(const rd_book *b, int32_t ch) {
    return (ch >= 0 && ch < b->nch) ? b->ch[ch]->text_len : 0;
}
int32_t rd_chapter_blocks(const rd_book *b, int32_t ch, const rd_block **out) {
    if (ch < 0 || ch >= b->nch) { if (out) *out = NULL; return 0; }
    if (out) *out = b->ch[ch]->blocks;
    return b->ch[ch]->nblocks;
}

int32_t rd_toc_count(const rd_book *b) { return b->ntoc; }
const char *rd_toc_title(const rd_book *b, int32_t i) { return (i >= 0 && i < b->ntoc) ? b->toc[i].title : ""; }
int32_t rd_toc_chapter(const rd_book *b, int32_t i) { return (i >= 0 && i < b->ntoc) ? b->toc[i].chapter : 0; }
int32_t rd_toc_block(const rd_book *b, int32_t i) { return (i >= 0 && i < b->ntoc) ? b->toc[i].block : 0; }
int32_t rd_toc_depth(const rd_book *b, int32_t i) { return (i >= 0 && i < b->ntoc) ? b->toc[i].depth : 0; }

unsigned char *rd_resource(const rd_book *b, const char *path, size_t *len) {
    if (!path || !*path) return NULL;
    if (b->kind == BK_EPUB) return zip_extract(&b->zip, zip_find(&b->zip, path), len);
    size_t n;
    char *data = read_file(path, &n);
    if (data && len) *len = n;
    return (unsigned char *)data;
}

unsigned char *rd_cover(const rd_book *b, size_t *len) {
    if (b->cover) {
        unsigned char *d = rd_resource(b, b->cover, len);
        if (d) return d;
    }
    for (int i = 0; i < b->nch && i < 3; i++)
        for (int k = 0; k < b->ch[i]->nblocks && k < 4; k++)
            if (b->ch[i]->blocks[k].type == RD_IMG) {
                unsigned char *d = rd_resource(b, b->ch[i]->blocks[k].text, len);
                if (d) return d;
            }
    return NULL;
}

void rd_free(void *p) { free(p); }
