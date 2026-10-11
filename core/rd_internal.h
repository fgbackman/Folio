/* Folio engine internals — not part of the public API. */
#ifndef FOLIO_RD_INTERNAL_H
#define FOLIO_RD_INTERNAL_H

#include "reader.h"
#include <stddef.h>
#include <stdint.h>

/* ---------- growable byte buffer ---------- */
typedef struct { char *data; size_t len, cap; } sbuf;
void  sb_reserve(sbuf *b, size_t extra);
void  sb_putc(sbuf *b, char c);
void  sb_put(sbuf *b, const char *s, size_t n);
void  sb_puts(sbuf *b, const char *s);
void  sb_utf8(sbuf *b, uint32_t cp);
void  sb_clear(sbuf *b);
void  sb_free(sbuf *b);
char *sb_cstr(sbuf *b);            /* NUL-terminate and return data */
char *xstrdup(const char *s);
char *xstrndup(const char *s, size_t n);

/* ---------- utf-8 ---------- */
uint32_t utf8_decode(const unsigned char *s, size_t n, size_t *adv);
int      utf8_valid(const unsigned char *s, size_t n);

/* ---------- zip ---------- */
typedef struct { char *name; uint32_t method, csize, usize, local_off; } zentry;
typedef struct { const unsigned char *buf; size_t len; zentry *e; int n; } zarchive;
int            zip_open_mem(zarchive *z, const unsigned char *buf, size_t len);
void           zip_close(zarchive *z);
int            zip_find(const zarchive *z, const char *name);
unsigned char *zip_extract(const zarchive *z, int idx, size_t *outlen);

/* ---------- xml / html tokenizer ---------- */
enum { XT_END = 0, XT_TEXT, XT_CDATA, XT_OPEN, XT_CLOSE };
typedef struct { const char *p, *end; } xtok;
typedef struct {
    int kind;
    const char *s; size_t n;            /* raw text (XT_TEXT / XT_CDATA) */
    char name[48];                      /* lowercased local tag name     */
    const char *attrs; size_t alen;     /* raw attribute string          */
    int selfclose;
} xtoken;
void xml_init(xtok *t, const char *s, size_t n);
int  xml_next(xtok *t, xtoken *k);
int  xml_attr(const char *attrs, size_t alen, const char *name, sbuf *out);
void decode_entities(const char *s, size_t n, sbuf *out);

/* ---------- book model ---------- */
typedef struct { char *id; int block; } anchor;

typedef struct {
    char     *path;                 /* zip path (EPUB) or NULL */
    char     *title;
    rd_block *blocks; int nblocks, capblocks;
    anchor   *anchors; int nanchors, capanchors;
    uint32_t  text_len;
    rd_link  *links; char **hrefs; int nlinks, caplinks;   /* hrefs[i] is dropped once links[i] is resolved */
} chapter;

typedef struct { char *title; int chapter, block, depth; char *href; } tocent;

enum { BK_EPUB = 0, BK_TEXT, BK_MARKDOWN, BK_HTML };

struct rd_book {
    int kind;
    unsigned char *file; size_t file_len;
    char *dir;                      /* folder containing the file (non-EPUB resources) */
    zarchive zip;
    char *title, *author, *cover;
    chapter **ch; int nch, capch;
    tocent *toc; int ntoc, captoc;
    uint64_t words;
};

chapter *book_add_chapter(rd_book *b, const char *path);
void     book_add_toc(rd_book *b, const char *title, int ch, int block, int depth, const char *href);

/* ---------- block builder (markup → blocks) ---------- */
typedef struct {
    rd_book *book;
    chapter *c;
    sbuf text;
    rd_span *spans; int nspans, capspans;
    int type;
    int ital, bold, code, pre, quote, skip, list;
    int cur_style; uint32_t run_start;
    int pending_space;
    const char *dir;                /* for resolving relative image paths */
    char **pend; int npend, cappend;/* anchors waiting for their block */
    char *link_href; uint32_t link_start;                 /* an <a href> that is still open */
    struct plink { uint32_t start, length; char *href; } *plinks; int nplinks, capplinks;
} builder;

void bld_init(builder *h, rd_book *book, chapter *c, const char *dir);
void bld_finish(builder *h);
void bld_set_type(builder *h, int type);
void bld_restyle(builder *h);
void bld_text(builder *h, const char *s, size_t n);   /* already entity-decoded */
void bld_raw(builder *h, const char *s, size_t n);    /* bypass whitespace collapsing */
void bld_flush(builder *h);
void bld_rule(builder *h);
void bld_image(builder *h, const char *path);
void bld_anchor(builder *h, const char *id);
void bld_link_open(builder *h, const char *href);
void bld_link_close(builder *h);
void chapter_add_link(chapter *c, int block, uint32_t start, uint32_t length, char *href);

/* Parse an (X)HTML document into chapter c. */
void html_to_chapter(rd_book *b, chapter *c, const char *html, size_t n, const char *dir,
                     sbuf *title_out);

/* path helpers */
char *path_dir(const char *path);                       /* "a/b/c.x" → "a/b/" */
char *path_resolve(const char *dir, const char *href);  /* strips #frag / ?query */

/* loaders */
int load_epub(rd_book *b, char *err, size_t errlen);
int load_text(rd_book *b, int markdown, const char *fallback_title);
int load_html(rd_book *b, const char *fallback_title);

#endif
