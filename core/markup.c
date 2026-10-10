/* Folio — tolerant XML/HTML tokenizer and the markup → styled-block builder. */
#include "rd_internal.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* ------------------------------------------------------------------ */
/* Entities                                                            */
/* ------------------------------------------------------------------ */

static const struct { const char *name; uint32_t cp; } ENTITIES[] = {
    {"amp", '&'}, {"lt", '<'}, {"gt", '>'}, {"quot", '"'}, {"apos", '\''},
    {"nbsp", 0xA0}, {"ensp", 0x2002}, {"emsp", 0x2003}, {"thinsp", 0x2009},
    {"mdash", 0x2014}, {"ndash", 0x2013}, {"hellip", 0x2026}, {"shy", 0xAD},
    {"lsquo", 0x2018}, {"rsquo", 0x2019}, {"sbquo", 0x201A}, {"ldquo", 0x201C},
    {"rdquo", 0x201D}, {"bdquo", 0x201E}, {"laquo", 0xAB}, {"raquo", 0xBB},
    {"lsaquo", 0x2039}, {"rsaquo", 0x203A}, {"prime", 0x2032}, {"Prime", 0x2033},
    {"copy", 0xA9}, {"reg", 0xAE}, {"trade", 0x2122}, {"deg", 0xB0},
    {"middot", 0xB7}, {"bull", 0x2022}, {"para", 0xB6}, {"sect", 0xA7},
    {"times", 0xD7}, {"divide", 0xF7}, {"plusmn", 0xB1}, {"frac12", 0xBD},
    {"frac14", 0xBC}, {"frac34", 0xBE}, {"sup1", 0xB9}, {"sup2", 0xB2},
    {"sup3", 0xB3}, {"pound", 0xA3}, {"euro", 0x20AC}, {"yen", 0xA5},
    {"cent", 0xA2}, {"dagger", 0x2020}, {"Dagger", 0x2021}, {"iexcl", 0xA1},
    {"iquest", 0xBF}, {"szlig", 0xDF}, {"AElig", 0xC6}, {"aelig", 0xE6},
    {"OElig", 0x152}, {"oelig", 0x153}, {"Ccedil", 0xC7}, {"ccedil", 0xE7},
    {"Ntilde", 0xD1}, {"ntilde", 0xF1}, {"Oslash", 0xD8}, {"oslash", 0xF8},
    {"Aring", 0xC5}, {"aring", 0xE5}, {"eth", 0xF0}, {"thorn", 0xFE},
    {"Agrave", 0xC0}, {"Aacute", 0xC1}, {"Acirc", 0xC2}, {"Atilde", 0xC3}, {"Auml", 0xC4},
    {"agrave", 0xE0}, {"aacute", 0xE1}, {"acirc", 0xE2}, {"atilde", 0xE3}, {"auml", 0xE4},
    {"Egrave", 0xC8}, {"Eacute", 0xC9}, {"Ecirc", 0xCA}, {"Euml", 0xCB},
    {"egrave", 0xE8}, {"eacute", 0xE9}, {"ecirc", 0xEA}, {"euml", 0xEB},
    {"Igrave", 0xCC}, {"Iacute", 0xCD}, {"Icirc", 0xCE}, {"Iuml", 0xCF},
    {"igrave", 0xEC}, {"iacute", 0xED}, {"icirc", 0xEE}, {"iuml", 0xEF},
    {"Ograve", 0xD2}, {"Oacute", 0xD3}, {"Ocirc", 0xD4}, {"Otilde", 0xD5}, {"Ouml", 0xD6},
    {"ograve", 0xF2}, {"oacute", 0xF3}, {"ocirc", 0xF4}, {"otilde", 0xF5}, {"ouml", 0xF6},
    {"Ugrave", 0xD9}, {"Uacute", 0xDA}, {"Ucirc", 0xDB}, {"Uuml", 0xDC},
    {"ugrave", 0xF9}, {"uacute", 0xFA}, {"ucirc", 0xFB}, {"uuml", 0xFC},
    {"Yacute", 0xDD}, {"yacute", 0xFD}, {"yuml", 0xFF}, {"zwnj", 0x200C}, {"zwj", 0x200D},
    {"alpha", 0x3B1}, {"beta", 0x3B2}, {"gamma", 0x3B3}, {"delta", 0x3B4}, {"pi", 0x3C0},
    {"larr", 0x2190}, {"rarr", 0x2192}, {"uarr", 0x2191}, {"darr", 0x2193},
};

void decode_entities(const char *s, size_t n, sbuf *out) {
    size_t i = 0;
    while (i < n) {
        const char *amp = memchr(s + i, '&', n - i);
        if (!amp) { sb_put(out, s + i, n - i); return; }
        size_t a = (size_t)(amp - s);
        sb_put(out, s + i, a - i);
        size_t j = a + 1;
        while (j < n && j - a < 12 && s[j] != ';' && s[j] != '&' && !isspace((unsigned char)s[j])) j++;
        if (j < n && s[j] == ';' && j > a + 1) {
            const char *e = s + a + 1; size_t el = j - a - 1;
            uint32_t cp = 0; int ok = 0;
            if (e[0] == '#') {
                char *endp; char tmp[16];
                size_t cl = el - 1 < 15 ? el - 1 : 15;
                memcpy(tmp, e + 1, cl); tmp[cl] = 0;
                long v = (tmp[0] == 'x' || tmp[0] == 'X') ? strtol(tmp + 1, &endp, 16) : strtol(tmp, &endp, 10);
                if (*endp == 0 && v > 0 && v < 0x110000) { cp = (uint32_t)v; ok = 1; }
            } else {
                for (size_t k = 0; k < sizeof ENTITIES / sizeof ENTITIES[0]; k++)
                    if (strlen(ENTITIES[k].name) == el && memcmp(ENTITIES[k].name, e, el) == 0) {
                        cp = ENTITIES[k].cp; ok = 1; break;
                    }
            }
            if (ok) { sb_utf8(out, cp); i = j + 1; continue; }
        }
        sb_putc(out, '&');
        i = a + 1;
    }
}

/* ------------------------------------------------------------------ */
/* Tokenizer                                                           */
/* ------------------------------------------------------------------ */

void xml_init(xtok *t, const char *s, size_t n) { t->p = s; t->end = s + n; }

static const char *find_str(const char *p, const char *e, const char *needle) {
    size_t nl = strlen(needle);
    while (p + nl <= e) {
        const char *q = memchr(p, needle[0], (size_t)(e - p));
        if (!q || q + nl > e) return NULL;
        if (memcmp(q, needle, nl) == 0) return q;
        p = q + 1;
    }
    return NULL;
}

int xml_next(xtok *t, xtoken *k) {
    for (;;) {
        const char *p = t->p, *e = t->end;
        k->selfclose = 0;
        if (p >= e) return k->kind = XT_END;

        if (*p != '<') {
            const char *q = memchr(p, '<', (size_t)(e - p));
            if (!q) q = e;
            k->kind = XT_TEXT; k->s = p; k->n = (size_t)(q - p); t->p = q;
            return XT_TEXT;
        }
        if (e - p >= 4 && memcmp(p, "<!--", 4) == 0) {
            const char *q = find_str(p + 4, e, "-->");
            t->p = q ? q + 3 : e;
            continue;
        }
        if (e - p >= 9 && memcmp(p, "<![CDATA[", 9) == 0) {
            const char *q = find_str(p + 9, e, "]]>");
            if (!q) q = e;
            k->kind = XT_CDATA; k->s = p + 9; k->n = (size_t)(q - p - 9);
            t->p = q < e ? q + 3 : e;
            return XT_CDATA;
        }
        if (e - p >= 2 && (p[1] == '!' || p[1] == '?')) {
            const char *q = memchr(p, '>', (size_t)(e - p));
            t->p = q ? q + 1 : e;
            continue;
        }

        int close = (e - p >= 2 && p[1] == '/');
        const char *q = p + 1 + close, *ns = q;
        while (q < e && !isspace((unsigned char)*q) && *q != '>' && *q != '/') q++;
        if (q == ns) {   /* a stray '<' in text */
            k->kind = XT_TEXT; k->s = p; k->n = 1; t->p = p + 1;
            return XT_TEXT;
        }
        const char *local = ns;
        for (const char *c = ns; c < q; c++) if (*c == ':') local = c + 1;
        size_t nl = (size_t)(q - local);
        if (nl >= sizeof k->name) nl = sizeof k->name - 1;
        for (size_t i = 0; i < nl; i++) k->name[i] = (char)tolower((unsigned char)local[i]);
        k->name[nl] = 0;

        const char *a = q; char quote = 0;
        while (q < e) {
            if (quote) { if (*q == quote) quote = 0; }
            else if (*q == '"' || *q == '\'') quote = *q;
            else if (*q == '>') break;
            q++;
        }
        k->attrs = a; k->alen = (size_t)(q - a);
        if (k->alen && a[k->alen - 1] == '/') { k->selfclose = 1; k->alen--; }
        t->p = q < e ? q + 1 : e;
        k->kind = close ? XT_CLOSE : XT_OPEN;
        return k->kind;
    }
}

/* Match on the full attribute name, or on its local part ("xlink:href" ~ "href"). */
int xml_attr(const char *a, size_t n, const char *name, sbuf *out) {
    const char *p = a, *e = a + n;
    size_t want = strlen(name);
    while (p < e) {
        while (p < e && (isspace((unsigned char)*p) || *p == '/')) p++;
        const char *ns = p;
        while (p < e && !isspace((unsigned char)*p) && *p != '=') p++;
        size_t nl = (size_t)(p - ns);
        while (p < e && isspace((unsigned char)*p)) p++;
        const char *vs = NULL; size_t vl = 0;
        if (p < e && *p == '=') {
            p++;
            while (p < e && isspace((unsigned char)*p)) p++;
            if (p < e && (*p == '"' || *p == '\'')) {
                char qc = *p++; vs = p;
                while (p < e && *p != qc) p++;
                vl = (size_t)(p - vs);
                if (p < e) p++;
            } else {
                vs = p;
                while (p < e && !isspace((unsigned char)*p)) p++;
                vl = (size_t)(p - vs);
            }
        }
        if (nl == 0) { if (p < e && !vs) p++; continue; }
        const char *local = ns;
        for (const char *c = ns; c < ns + nl; c++) if (*c == ':') local = c + 1;
        size_t ll = (size_t)(ns + nl - local);
        if ((nl == want && strncasecmp(ns, name, nl) == 0) ||
            (ll == want && strncasecmp(local, name, ll) == 0)) {
            sb_clear(out);
            if (vs) decode_entities(vs, vl, out);
            sb_cstr(out);
            return 1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Block builder                                                       */
/* ------------------------------------------------------------------ */

void bld_init(builder *h, rd_book *book, chapter *c, const char *dir) {
    memset(h, 0, sizeof *h);
    h->book = book; h->c = c; h->dir = dir; h->type = RD_P;
}

static int cur_style(const builder *h) {
    return (h->ital > 0 ? RD_STYLE_ITALIC : 0) | (h->bold > 0 ? RD_STYLE_BOLD : 0) |
           (h->code > 0 ? RD_STYLE_CODE : 0);
}

static void run_close(builder *h) {
    if (h->cur_style && h->text.len > h->run_start) {
        if (h->nspans == h->capspans) {
            h->capspans = h->capspans ? h->capspans * 2 : 8;
            h->spans = realloc(h->spans, sizeof *h->spans * (size_t)h->capspans);
        }
        h->spans[h->nspans++] = (rd_span){h->run_start, (uint32_t)h->text.len - h->run_start, h->cur_style};
    }
    h->run_start = (uint32_t)h->text.len;
}

void bld_restyle(builder *h) {
    int s = cur_style(h);
    if (s != h->cur_style) { run_close(h); h->cur_style = s; }
}

void bld_set_type(builder *h, int type) { h->type = type; }

void bld_raw(builder *h, const char *s, size_t n) {
    if (h->skip) return;
    sb_put(&h->text, s, n);
    h->pending_space = 0;
}

void bld_text(builder *h, const char *s, size_t n) {
    if (h->skip) return;
    if (h->pre) {
        for (size_t i = 0; i < n; i++) if (s[i] != '\r') sb_putc(&h->text, s[i]);
        return;
    }
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f') { h->pending_space = 1; continue; }
        if (h->pending_space && h->text.len) {
            char last = h->text.data[h->text.len - 1];
            if (last != ' ' && last != '\n') {
                int at_run_start = h->text.len == h->run_start;
                sb_putc(&h->text, ' ');
                if (at_run_start) h->run_start = (uint32_t)h->text.len;   /* keep the space out of styled runs */
            }
        }
        h->pending_space = 0;
        sb_putc(&h->text, c);
    }
}

static void push_block(builder *h, int type, const char *text, size_t len, rd_span *spans, int nspans) {
    chapter *c = h->c;
    if (c->nblocks == c->capblocks) {
        c->capblocks = c->capblocks ? c->capblocks * 2 : 32;
        c->blocks = realloc(c->blocks, sizeof *c->blocks * (size_t)c->capblocks);
    }
    rd_span *sp = NULL;
    if (nspans) { sp = malloc(sizeof *sp * (size_t)nspans); memcpy(sp, spans, sizeof *sp * (size_t)nspans); }
    c->blocks[c->nblocks++] = (rd_block){type, xstrndup(text, len), (uint32_t)len, sp, nspans};
    c->text_len += (uint32_t)len;

    /* word count */
    int inword = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)text[i];
        int sp_ = (ch == ' ' || ch == '\n' || ch == '\t');
        if (!sp_ && !inword) h->book->words++;
        inword = !sp_;
    }
    /* anchors waiting for a block */
    for (int i = 0; i < h->npend; i++) {
        if (c->nanchors == c->capanchors) {
            c->capanchors = c->capanchors ? c->capanchors * 2 : 8;
            c->anchors = realloc(c->anchors, sizeof *c->anchors * (size_t)c->capanchors);
        }
        c->anchors[c->nanchors++] = (anchor){h->pend[i], c->nblocks - 1};
    }
    h->npend = 0;
}

void bld_flush(builder *h) {
    run_close(h);
    size_t len = h->text.len;
    while (len && (h->text.data[len - 1] == ' ' || h->text.data[len - 1] == '\n' ||
                   h->text.data[len - 1] == '\t'))
        len--;
    size_t start = 0;
    if (h->type == RD_PRE) while (start < len && h->text.data[start] == '\n') start++;
    if (len > start) {
        int ns = 0;
        for (int i = 0; i < h->nspans; i++) {
            rd_span s = h->spans[i];
            if (s.start < start) { uint32_t d = (uint32_t)start - s.start; if (d >= s.length) continue; s.start = (uint32_t)start; s.length -= d; }
            if (s.start >= len) continue;
            if (s.start + s.length > len) s.length = (uint32_t)len - s.start;
            s.start -= (uint32_t)start;
            if (s.length) h->spans[ns++] = s;
        }
        push_block(h, h->type, h->text.data + start, len - start, h->spans, ns);
    }
    sb_clear(&h->text);
    h->nspans = 0;
    h->run_start = 0;
    h->pending_space = 0;
}

void bld_rule(builder *h) {
    bld_flush(h);
    push_block(h, RD_HR, "", 0, NULL, 0);
}

void bld_image(builder *h, const char *path) {
    bld_flush(h);
    push_block(h, RD_IMG, path, strlen(path), NULL, 0);
}

void bld_anchor(builder *h, const char *id) {
    if (!id || !*id) return;
    if (h->npend == h->cappend) {
        h->cappend = h->cappend ? h->cappend * 2 : 4;
        h->pend = realloc(h->pend, sizeof *h->pend * (size_t)h->cappend);
    }
    h->pend[h->npend++] = xstrdup(id);
}

void bld_finish(builder *h) {
    bld_flush(h);
    chapter *c = h->c;
    for (int i = 0; i < h->npend; i++) {     /* trailing anchors point at the last block */
        if (c->nanchors == c->capanchors) {
            c->capanchors = c->capanchors ? c->capanchors * 2 : 8;
            c->anchors = realloc(c->anchors, sizeof *c->anchors * (size_t)c->capanchors);
        }
        c->anchors[c->nanchors++] = (anchor){h->pend[i], c->nblocks ? c->nblocks - 1 : 0};
    }
    free(h->pend); free(h->spans); sb_free(&h->text);
    h->pend = NULL; h->spans = NULL; h->npend = 0;
}

/* ------------------------------------------------------------------ */
/* HTML → blocks                                                       */
/* ------------------------------------------------------------------ */

static int is_one_of(const char *name, const char *const *list) {
    for (; *list; list++) if (strcmp(name, *list) == 0) return 1;
    return 0;
}

static const char *const SKIP_TAGS[] = {"head", "script", "style", "noscript", "template", NULL};
static const char *const BLOCK_TAGS[] = {"p", "div", "section", "article", "header", "footer",
    "aside", "figure", "figcaption", "dd", "dt", "center", "address", "tr", "table", "body",
    "main", "nav", "dl", "ol", "ul", "caption", "details", "summary", "hgroup", NULL};
static const char *const ITALIC_TAGS[] = {"i", "em", "cite", "dfn", "var", "q", NULL};
static const char *const BOLD_TAGS[] = {"b", "strong", NULL};
static const char *const CODE_TAGS[] = {"code", "kbd", "samp", "tt", NULL};

static int heading_type(const char *n) {
    if (n[0] == 'h' && n[1] >= '1' && n[1] <= '6' && n[2] == 0)
        return n[1] == '1' ? RD_H1 : n[1] == '2' ? RD_H2 : RD_H3;
    return -1;
}

static int base_type(const builder *h) {
    return h->pre ? RD_PRE : h->quote ? RD_QUOTE : RD_P;
}

void html_to_chapter(rd_book *b, chapter *c, const char *html, size_t n, const char *dir,
                     sbuf *title_out) {
    builder h;
    bld_init(&h, b, c, dir);
    xtok t; xtoken k;
    xml_init(&t, html, n);
    sbuf tmp = {0}, attr = {0};
    int in_title = 0;

    while (xml_next(&t, &k) != XT_END) {
        if (k.kind == XT_TEXT || k.kind == XT_CDATA) {
            if (in_title && title_out) {
                if (k.kind == XT_TEXT) decode_entities(k.s, k.n, title_out); else sb_put(title_out, k.s, k.n);
                continue;
            }
            if (h.skip) continue;
            sb_clear(&tmp);
            if (k.kind == XT_TEXT) decode_entities(k.s, k.n, &tmp); else sb_put(&tmp, k.s, k.n);
            bld_text(&h, tmp.data ? tmp.data : "", tmp.len);
            continue;
        }

        const char *nm = k.name;
        if (k.kind == XT_OPEN) {
            if (strcmp(nm, "title") == 0 && !k.selfclose) { in_title = 1; continue; }
            if (is_one_of(nm, SKIP_TAGS)) { if (!k.selfclose) h.skip++; continue; }
            if (h.skip) continue;

            if (xml_attr(k.attrs, k.alen, "id", &attr) && attr.len) bld_anchor(&h, attr.data);

            int ht = heading_type(nm);
            if (ht >= 0) { bld_flush(&h); bld_set_type(&h, ht); if (k.selfclose) bld_set_type(&h, base_type(&h)); continue; }
            if (strcmp(nm, "li") == 0) { bld_flush(&h); bld_set_type(&h, RD_LI); continue; }
            if (strcmp(nm, "blockquote") == 0) { bld_flush(&h); if (!k.selfclose) h.quote++; bld_set_type(&h, base_type(&h)); continue; }
            if (strcmp(nm, "pre") == 0) { bld_flush(&h); if (!k.selfclose) h.pre++; bld_set_type(&h, base_type(&h)); continue; }
            if (strcmp(nm, "br") == 0) { if (h.text.len) { sb_putc(&h.text, '\n'); h.pending_space = 0; } continue; }
            if (strcmp(nm, "hr") == 0) { bld_rule(&h); continue; }
            if (strcmp(nm, "img") == 0 || strcmp(nm, "image") == 0) {
                if ((xml_attr(k.attrs, k.alen, "src", &attr) || xml_attr(k.attrs, k.alen, "href", &attr)) &&
                    attr.len && strncmp(attr.data, "data:", 5) != 0) {
                    char *p = path_resolve(dir, attr.data);
                    bld_image(&h, p);
                    free(p);
                }
                continue;
            }
            if (strcmp(nm, "td") == 0 || strcmp(nm, "th") == 0) { h.pending_space = 1; continue; }
            if (is_one_of(nm, BLOCK_TAGS)) {
                bld_flush(&h);
                if (h.type != RD_LI || strcmp(nm, "p") != 0) bld_set_type(&h, base_type(&h));
                continue;
            }
            if (k.selfclose) continue;
            if (is_one_of(nm, ITALIC_TAGS)) { h.ital++; bld_restyle(&h); }
            else if (is_one_of(nm, BOLD_TAGS)) { h.bold++; bld_restyle(&h); }
            else if (is_one_of(nm, CODE_TAGS)) { h.code++; bld_restyle(&h); }
            continue;
        }

        /* closing tag */
        if (strcmp(nm, "title") == 0) { in_title = 0; continue; }
        if (is_one_of(nm, SKIP_TAGS)) { if (h.skip) h.skip--; continue; }
        if (h.skip) continue;
        if (heading_type(nm) >= 0 || strcmp(nm, "li") == 0) { bld_flush(&h); bld_set_type(&h, base_type(&h)); continue; }
        if (strcmp(nm, "blockquote") == 0) { bld_flush(&h); if (h.quote) h.quote--; bld_set_type(&h, base_type(&h)); continue; }
        if (strcmp(nm, "pre") == 0) { bld_flush(&h); if (h.pre) h.pre--; bld_set_type(&h, base_type(&h)); continue; }
        if (is_one_of(nm, BLOCK_TAGS)) {
            bld_flush(&h);
            if (h.type != RD_LI || strcmp(nm, "p") != 0) bld_set_type(&h, base_type(&h));
            continue;
        }
        if (is_one_of(nm, ITALIC_TAGS)) { if (h.ital) h.ital--; bld_restyle(&h); }
        else if (is_one_of(nm, BOLD_TAGS)) { if (h.bold) h.bold--; bld_restyle(&h); }
        else if (is_one_of(nm, CODE_TAGS)) { if (h.code) h.code--; bld_restyle(&h); }
    }
    bld_finish(&h);
    sb_free(&tmp); sb_free(&attr);
}
