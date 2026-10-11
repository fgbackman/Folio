/* Folio — plain text (Project Gutenberg aware), Markdown and single-file HTML loaders. */
#include "rd_internal.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* Windows-1252 0x80–0x9F; everything else in 0xA0–0xFF is Latin-1. */
static const uint16_t CP1252[32] = {
    0x20AC, 0x81, 0x201A, 0x192, 0x201E, 0x2026, 0x2020, 0x2021, 0x2C6, 0x2030, 0x160, 0x2039, 0x152, 0x8D, 0x17D, 0x8F,
    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x2DC, 0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x17E, 0x178};

/* Decode to UTF-8 with \n line endings. */
static char *normalize_text(const unsigned char *s, size_t n, size_t *outn) {
    if (n >= 3 && s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF) { s += 3; n -= 3; }
    int valid = utf8_valid(s, n);
    sbuf o = {0};
    sb_reserve(&o, n);
    for (size_t i = 0; i < n; i++) {
        unsigned char c = s[i];
        if (c == '\r') { sb_putc(&o, '\n'); if (i + 1 < n && s[i + 1] == '\n') i++; continue; }
        if (valid || c < 0x80) sb_putc(&o, (char)c);
        else sb_utf8(&o, c < 0xA0 ? CP1252[c - 0x80] : c);
    }
    *outn = o.len;
    return sb_cstr(&o);
}

typedef struct { char *s; size_t n; } line_t;

static size_t split_lines(char *buf, size_t n, line_t **out) {
    size_t cap = 256, cnt = 0;
    line_t *L = malloc(sizeof *L * cap);
    char *p = buf, *e = buf + n;
    while (p < e) {
        char *nl = memchr(p, '\n', (size_t)(e - p));
        char *end = nl ? nl : e;
        if (cnt == cap) { cap *= 2; L = realloc(L, sizeof *L * cap); }
        *end = 0;
        L[cnt++] = (line_t){p, (size_t)(end - p)};
        p = nl ? nl + 1 : e;
    }
    *out = L;
    return cnt;
}

static void trim(const char **s, size_t *n) {
    while (*n && isspace((unsigned char)**s)) { (*s)++; (*n)--; }
    while (*n && isspace((unsigned char)(*s)[*n - 1])) (*n)--;
}

static int blank(line_t l) { const char *s = l.s; size_t n = l.n; trim(&s, &n); return n == 0; }

/* ---------- inline emphasis: _italic_ (both), *italic* **bold** `code` [link](url) (Markdown) ---------- */
static void emit_inline(builder *h, const char *s, size_t n, int md) {
    size_t i = 0, run = 0;
#define FLUSH_RUN() do { if (i > run) bld_text(h, s + run, i - run); } while (0)
    while (i < n) {
        char c = s[i];
        char prev = i ? s[i - 1] : ' ', next = i + 1 < n ? s[i + 1] : ' ';
        if (h->code && md) {
            if (c == '`') { FLUSH_RUN(); h->code = 0; bld_restyle(h); run = ++i; continue; }
            i++; continue;
        }
        if (md && c == '\\' && i + 1 < n && ispunct((unsigned char)next)) { FLUSH_RUN(); run = i + 1; i += 2; continue; }
        if (md && c == '`') { FLUSH_RUN(); h->code = 1; bld_restyle(h); run = ++i; continue; }
        if (md && c == '*' && next == '*') { FLUSH_RUN(); h->bold = !h->bold; bld_restyle(h); i += 2; run = i; continue; }
        if (md && c == '*' && (h->ital ? !isspace((unsigned char)prev) : !isspace((unsigned char)next))) {
            FLUSH_RUN(); h->ital = !h->ital; bld_restyle(h); run = ++i; continue;
        }
        if (c == '_') {
            int opening = !h->ital && !isalnum((unsigned char)prev) && !isspace((unsigned char)next) && next != '_';
            int closing = h->ital && !isspace((unsigned char)prev) && !isalnum((unsigned char)next);
            if (opening || closing) { FLUSH_RUN(); h->ital = !h->ital; bld_restyle(h); run = ++i; continue; }
        }
        if (md && c == '[') {
            const char *close = memchr(s + i, ']', n - i);
            if (close && (size_t)(close - s) + 1 < n && close[1] == '(') {
                const char *paren = memchr(close, ')', (size_t)(s + n - close));
                if (paren) {
                    FLUSH_RUN();
                    emit_inline(h, s + i + 1, (size_t)(close - s - i - 1), md);
                    i = (size_t)(paren - s) + 1; run = i; continue;
                }
            }
        }
        i++;
    }
    FLUSH_RUN();
#undef FLUSH_RUN
}

static void end_para(builder *h) {
    bld_flush(h);
    h->ital = h->bold = h->code = 0;
    bld_restyle(h);
    bld_set_type(h, RD_P);
}

static void new_chapter(rd_book *b, builder *h) {
    if (h->c->nblocks == 0) return;          /* reuse an empty chapter */
    bld_finish(h);
    chapter *c = book_add_chapter(b, NULL);
    const char *dir = h->dir;
    bld_init(h, b, c, dir);
}

/* ---------- plain text ---------- */

static const char *const CHAPTER_WORDS[] = {"chapter", "book", "part", "letter", "volume", "act",
    "stave", "canto", "prologue", "epilogue", "preface", "introduction", "foreword", "afterword",
    "appendix", "interlude", NULL};

static int is_roman_or_number(const char *s, size_t n) {
    if (n && s[n - 1] == '.') n--;
    if (n == 0 || n > 8) return 0;
    int roman = 1, digits = 1;
    for (size_t i = 0; i < n; i++) {
        if (!strchr("IVXLCDM", s[i])) roman = 0;
        if (!isdigit((unsigned char)s[i])) digits = 0;
    }
    return roman || (digits && n <= 3);
}

static int chapter_heading(const char *s, size_t n) {
    trim(&s, &n);
    if (n == 0 || n > 80) return 0;
    for (int i = 0; CHAPTER_WORDS[i]; i++) {
        size_t wl = strlen(CHAPTER_WORDS[i]);
        if (n >= wl && strncasecmp(s, CHAPTER_WORDS[i], wl) == 0 &&
            (n == wl || s[wl] == ' ' || s[wl] == '.' || s[wl] == ':')) {
            /* "Chapter" must look like a heading, not a sentence: short, few lowercase words */
            int words = 1;
            for (size_t j = 0; j < n; j++) if (s[j] == ' ') words++;
            if (words <= 8) return 1;
        }
    }
    return is_roman_or_number(s, n);
}

static int caps_heading(const char *s, size_t n) {
    trim(&s, &n);
    if (n < 2 || n > 60) return 0;
    int letters = 0;
    for (size_t i = 0; i < n; i++) {
        if (islower((unsigned char)s[i])) return 0;
        if (isupper((unsigned char)s[i])) letters++;
    }
    return letters >= 2;
}

static int rule_line(const char *s, size_t n) {
    trim(&s, &n);
    if (n < 3) return 0;
    int marks = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '*' || s[i] == '-' || s[i] == '_' || s[i] == '=' || s[i] == '#' || s[i] == '~') marks++;
        else if (s[i] != ' ') return 0;
    }
    return marks >= 3;
}

static void meta_line(rd_book *b, const char *s, size_t n) {
    trim(&s, &n);
    if (!b->title && n > 7 && strncasecmp(s, "Title: ", 7) == 0) b->title = xstrndup(s + 7, n - 7);
    if (!b->author && n > 8 && strncasecmp(s, "Author: ", 8) == 0) b->author = xstrndup(s + 8, n - 8);
}

static void text_body(rd_book *b, builder *h, line_t *L, size_t nl) {
    size_t i = 0;
    while (i < nl) {
        if (blank(L[i])) { i++; continue; }
        size_t j = i;
        while (j < nl && !blank(L[j])) j++;
        size_t cnt = j - i;

        const char *s0 = L[i].s; size_t n0 = L[i].n; trim(&s0, &n0);
        int short_lines = 1;
        for (size_t k = i; k < j; k++) { const char *s = L[k].s; size_t n = L[k].n; trim(&s, &n); if (n >= 55) short_lines = 0; }

        if (cnt <= 2 && short_lines && chapter_heading(s0, n0)) {
            new_chapter(b, h);
            bld_set_type(h, RD_H2);
            for (size_t k = i; k < j; k++) {
                const char *s = L[k].s; size_t n = L[k].n; trim(&s, &n);
                if (k > i) bld_text(h, " \xE2\x80\x94 ", 5);
                emit_inline(h, s, n, 0);
            }
            end_para(h);
        } else if (cnt == 1 && rule_line(s0, n0)) {
            bld_rule(h);
        } else if (cnt == 1 && caps_heading(s0, n0)) {
            bld_set_type(h, RD_H3);
            emit_inline(h, s0, n0, 0);
            end_para(h);
        } else {
            int verse = cnt >= 2 && short_lines;
            for (size_t k = i; k < j; k++) {
                const char *s = L[k].s; size_t n = L[k].n; trim(&s, &n);
                if (k > i) { if (verse) bld_raw(h, "\n", 1); else bld_text(h, " ", 1); }
                emit_inline(h, s, n, 0);
            }
            end_para(h);
        }
        i = j;
    }
}

/* ---------- Markdown ---------- */

static int md_heading_level(const char *s, size_t n, const char **text, size_t *tn) {
    size_t lv = 0;
    while (lv < n && s[lv] == '#') lv++;
    if (lv == 0 || lv > 6 || (lv < n && s[lv] != ' ')) return 0;
    const char *t = s + lv; size_t m = n - lv;
    trim(&t, &m);
    while (m && t[m - 1] == '#') m--;
    trim(&t, &m);
    *text = t; *tn = m;
    return (int)lv;
}

static int md_list_item(const char *s, size_t n, size_t *skip) {
    if (n >= 2 && (s[0] == '-' || s[0] == '*' || s[0] == '+') && s[1] == ' ') { *skip = 2; return 1; }
    size_t d = 0;
    while (d < n && isdigit((unsigned char)s[d])) d++;
    if (d && d + 1 < n && (s[d] == '.' || s[d] == ')') && s[d + 1] == ' ') { *skip = d + 2; return 1; }
    return 0;
}

static void markdown_body(rd_book *b, builder *h, line_t *L, size_t nl) {
    /* split chapters at the shallowest heading level used */
    int split = 7;
    for (size_t i = 0; i < nl; i++) {
        const char *t; size_t tn;
        const char *s = L[i].s; size_t n = L[i].n; trim(&s, &n);
        int lv = md_heading_level(s, n, &t, &tn);
        if (lv && lv < split) split = lv;
    }
    int in_code = 0;
    for (size_t i = 0; i < nl; i++) {
        const char *raw = L[i].s; size_t rn = L[i].n;
        const char *s = raw; size_t n = rn; trim(&s, &n);

        if (in_code) {
            if (n >= 3 && strncmp(s, "```", 3) == 0) { h->pre = 0; end_para(h); in_code = 0; }
            else { if (h->text.len) bld_raw(h, "\n", 1); bld_raw(h, raw, rn); }
            continue;
        }
        if (n >= 3 && strncmp(s, "```", 3) == 0) { end_para(h); bld_set_type(h, RD_PRE); h->pre = 1; in_code = 1; continue; }
        if (n == 0) { end_para(h); continue; }

        const char *t; size_t tn, skip;
        int lv = md_heading_level(s, n, &t, &tn);
        if (lv) {
            end_para(h);
            if (lv == split) new_chapter(b, h);
            bld_set_type(h, lv == 1 ? RD_H1 : lv == 2 ? RD_H2 : RD_H3);
            emit_inline(h, t, tn, 1);
            end_para(h);
            continue;
        }
        if (rule_line(s, n) && (s[0] == '-' || s[0] == '*' || s[0] == '_')) { end_para(h); bld_rule(h); continue; }
        if (n > 4 && s[0] == '!' && s[1] == '[' && s[n - 1] == ')') {
            const char *paren = memchr(s, '(', n);
            if (paren) {
                char *src = xstrndup(paren + 1, (size_t)(s + n - 1 - paren - 1));
                char *sp = strchr(src, ' '); if (sp) *sp = 0;       /* drop "title" */
                char *path = path_resolve(h->dir, src);
                end_para(h); bld_image(h, path);
                free(path); free(src);
                continue;
            }
        }
        if (s[0] == '>') {
            const char *q = s + 1; size_t qn = n - 1; trim(&q, &qn);
            if (h->type != RD_QUOTE) { end_para(h); bld_set_type(h, RD_QUOTE); }
            if (qn == 0) { end_para(h); bld_set_type(h, RD_QUOTE); continue; }
            bld_text(h, " ", 1);
            emit_inline(h, q, qn, 1);
            continue;
        }
        if (md_list_item(s, n, &skip)) {
            end_para(h); bld_set_type(h, RD_LI);
            emit_inline(h, s + skip, n - skip, 1);
            continue;
        }
        if (h->type == RD_QUOTE && h->text.len == 0) bld_set_type(h, RD_P);
        bld_text(h, " ", 1);
        emit_inline(h, s, n, 1);
        if (rn >= 2 && raw[rn - 1] == ' ' && raw[rn - 2] == ' ') bld_raw(h, "\n", 1);   /* hard break */
    }
    h->pre = 0;
}

int load_text(rd_book *b, int markdown, const char *fallback_title) {
    size_t n;
    char *buf = normalize_text(b->file, b->file_len, &n);
    char *body = buf; size_t bn = n;

    if (!markdown) {
        /* Project Gutenberg boilerplate */
        char *start = strstr(buf, "*** START OF");
        if (!start) start = strstr(buf, "***START OF");
        if (start) {
            /* header metadata */
            line_t *H; char *hdr = xstrndup(buf, (size_t)(start - buf));
            size_t hn = split_lines(hdr, (size_t)(start - buf), &H);
            for (size_t i = 0; i < hn; i++) meta_line(b, H[i].s, H[i].n);
            free(H); free(hdr);
            char *eol = strchr(start, '\n');
            body = eol ? eol + 1 : buf + n;
            bn = n - (size_t)(body - buf);
        }
        char *end = strstr(body, "*** END OF");
        if (!end) end = strstr(body, "***END OF");
        if (end) bn = (size_t)(end - body);
    }

    line_t *L;
    size_t nl = split_lines(body, bn, &L);
    if (!markdown && !b->title) for (size_t i = 0; i < nl && i < 40; i++) meta_line(b, L[i].s, L[i].n);

    char *dir = xstrdup(b->dir ? b->dir : "");
    builder h;
    bld_init(&h, b, book_add_chapter(b, NULL), dir);
    if (markdown) markdown_body(b, &h, L, nl);
    else text_body(b, &h, L, nl);
    bld_finish(&h);

    /* drop a trailing empty chapter */
    if (b->nch > 1 && b->ch[b->nch - 1]->nblocks == 0) { free(b->ch[b->nch - 1]); b->nch--; }

    if (!b->title && markdown) {
        for (int c = 0; c < b->nch && !b->title; c++)
            for (int i = 0; i < b->ch[c]->nblocks; i++)
                if (b->ch[c]->blocks[i].type == RD_H1) { b->title = xstrdup(b->ch[c]->blocks[i].text); break; }
    }
    if (!b->title) b->title = xstrdup(fallback_title);
    free(L); free(buf); free(dir);
    return 0;
}

/* <meta name="author" content="…"> in the head of a single-file book. */
static void html_author(rd_book *b) {
    xtok t; xtoken k;
    sbuf name = {0}, content = {0};
    xml_init(&t, (const char *)b->file, b->file_len);
    while (!b->author && xml_next(&t, &k) != XT_END) {
        if (k.kind != XT_OPEN) continue;
        if (strcmp(k.name, "body") == 0) break;
        if (strcmp(k.name, "meta") != 0) continue;
        sb_clear(&name); sb_clear(&content);
        if (xml_attr(k.attrs, k.alen, "name", &name) && name.len && strcasecmp(sb_cstr(&name), "author") == 0 &&
            xml_attr(k.attrs, k.alen, "content", &content) && content.len) {
            const char *s = sb_cstr(&content); size_t n = content.len;
            trim(&s, &n);
            if (n) b->author = xstrndup(s, n);
        }
    }
    sb_free(&name); sb_free(&content);
}

/* A single file with several top-level headings is a book of several chapters. */
static void split_at_h1(rd_book *b) {
    chapter *src = b->ch[0];
    int heads = 0;
    for (int k = 0; k < src->nblocks; k++) if (src->blocks[k].type == RD_H1) heads++;
    if (heads < 2) return;

    rd_block *blocks = src->blocks; int n = src->nblocks;
    anchor *anchors = src->anchors; int na = src->nanchors;
    src->blocks = NULL; src->nblocks = src->capblocks = 0;
    src->anchors = NULL; src->nanchors = src->capanchors = 0;
    src->text_len = 0;

    chapter *c = src;
    int a = 0;
    for (int k = 0; k < n; k++) {
        if (blocks[k].type == RD_H1 && c->nblocks > 0) c = book_add_chapter(b, NULL);
        if (c->nblocks == c->capblocks) {
            c->capblocks = c->capblocks ? c->capblocks * 2 : 32;
            c->blocks = realloc(c->blocks, sizeof *c->blocks * (size_t)c->capblocks);
        }
        c->blocks[c->nblocks++] = blocks[k];
        c->text_len += blocks[k].text_len;
        for (; a < na && anchors[a].block <= k; a++) {      /* anchors are in block order */
            if (c->nanchors == c->capanchors) {
                c->capanchors = c->capanchors ? c->capanchors * 2 : 8;
                c->anchors = realloc(c->anchors, sizeof *c->anchors * (size_t)c->capanchors);
            }
            c->anchors[c->nanchors++] = (anchor){anchors[a].id, c->nblocks - 1};
        }
    }
    for (; a < na; a++) free(anchors[a].id);
    free(blocks); free(anchors);
}

int load_html(rd_book *b, const char *fallback_title) {
    chapter *c = book_add_chapter(b, NULL);
    sbuf title = {0};
    html_to_chapter(b, c, (const char *)b->file, b->file_len, b->dir ? b->dir : "", &title);
    if (title.len) {
        const char *s = sb_cstr(&title); size_t n = title.len;
        trim(&s, &n);
        if (n) b->title = xstrndup(s, n);
    }
    sb_free(&title);
    if (!b->title) b->title = xstrdup(fallback_title);
    html_author(b);
    split_at_h1(b);
    return 0;
}
