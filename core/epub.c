/* Folio — EPUB 2/3 loader: container → OPF → spine chapters, nav/NCX table of contents, cover. */
#define _GNU_SOURCE
#include "rd_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

typedef struct { char *id, *path, *mtype, *props; } mitem;

static void seterr(char *err, size_t n, const char *msg) { if (err && n) snprintf(err, n, "%s", msg); }

static unsigned char *zip_get(rd_book *b, const char *path, size_t *len) {
    return zip_extract(&b->zip, zip_find(&b->zip, path), len);
}

/* Collect text until the matching close tag; returns a trimmed malloc'd string. */
static char *collect_text(xtok *t, const char *tag) {
    xtoken k; sbuf s = {0}; int depth = 0;
    while (xml_next(t, &k) != XT_END) {
        if (k.kind == XT_TEXT) decode_entities(k.s, k.n, &s);
        else if (k.kind == XT_CDATA) sb_put(&s, k.s, k.n);
        else if (k.kind == XT_OPEN && !k.selfclose && strcmp(k.name, tag) == 0) depth++;
        else if (k.kind == XT_CLOSE && strcmp(k.name, tag) == 0) { if (depth-- == 0) break; }
    }
    /* collapse whitespace */
    sbuf o = {0}; int sp = 0;
    for (size_t i = 0; i < s.len; i++) {
        char c = s.data[i];
        if (c == ' ' || c == '\n' || c == '\t' || c == '\r') { sp = 1; continue; }
        if (sp && o.len) sb_putc(&o, ' ');
        sp = 0; sb_putc(&o, c);
    }
    char *r = xstrdup(o.data ? sb_cstr(&o) : "");
    sb_free(&s); sb_free(&o);
    return r;
}

static int chapter_for_path(rd_book *b, const char *path) {
    for (int i = 0; i < b->nch; i++) if (b->ch[i]->path && strcmp(b->ch[i]->path, path) == 0) return i;
    for (int i = 0; i < b->nch; i++) if (b->ch[i]->path && strcasecmp(b->ch[i]->path, path) == 0) return i;
    return -1;
}

static void add_toc_href(rd_book *b, const char *title, const char *dir, const char *href, int depth) {
    if (!title || !*title || !href) return;
    char *path = path_resolve(dir, href);
    const char *frag = strchr(href, '#');
    int ch = chapter_for_path(b, path);
    free(path);
    if (ch < 0) return;
    int block = 0;
    if (frag && frag[1]) {
        chapter *c = b->ch[ch];
        for (int i = 0; i < c->nanchors; i++) if (strcmp(c->anchors[i].id, frag + 1) == 0) { block = c->anchors[i].block; break; }
    }
    book_add_toc(b, title, ch, block, depth < 0 ? 0 : depth, href);
}

/* EPUB 3 navigation document: <nav epub:type="toc"><ol><li><a href>…</a> */
static int parse_nav(rd_book *b, const char *path) {
    size_t n; unsigned char *data = zip_get(b, path, &n);
    if (!data) return 0;
    char *dir = path_dir(path);
    xtok t; xtoken k; sbuf attr = {0};
    xml_init(&t, (const char *)data, n);
    int in_toc = 0, navdepth = 0, oldepth = 0, before = b->ntoc;
    while (xml_next(&t, &k) != XT_END) {
        if (k.kind == XT_OPEN && strcmp(k.name, "nav") == 0) {
            if (in_toc) navdepth++;
            else if (xml_attr(k.attrs, k.alen, "type", &attr) && strstr(attr.data, "toc")) { in_toc = 1; navdepth = 0; }
            continue;
        }
        if (!in_toc) continue;
        if (k.kind == XT_CLOSE && strcmp(k.name, "nav") == 0) { if (navdepth-- == 0) break; continue; }
        if (k.kind == XT_OPEN && strcmp(k.name, "ol") == 0 && !k.selfclose) oldepth++;
        else if (k.kind == XT_CLOSE && strcmp(k.name, "ol") == 0) oldepth--;
        else if (k.kind == XT_OPEN && strcmp(k.name, "a") == 0 && !k.selfclose) {
            char *href = xml_attr(k.attrs, k.alen, "href", &attr) ? xstrdup(attr.data) : NULL;
            char *title = collect_text(&t, "a");
            add_toc_href(b, title, dir, href, oldepth - 1);
            free(href); free(title);
        }
    }
    sb_free(&attr); free(dir); free(data);
    return b->ntoc > before;
}

/* EPUB 2 NCX: <navPoint><navLabel><text>…</text></navLabel><content src=…/> */
static int parse_ncx(rd_book *b, const char *path) {
    size_t n; unsigned char *data = zip_get(b, path, &n);
    if (!data) return 0;
    char *dir = path_dir(path);
    xtok t; xtoken k; sbuf attr = {0};
    xml_init(&t, (const char *)data, n);
    int depth = 0, before = b->ntoc, in_map = 0;
    char *label = NULL;
    while (xml_next(&t, &k) != XT_END) {
        if (k.kind == XT_OPEN && strcmp(k.name, "navmap") == 0) { in_map = 1; continue; }
        if (k.kind == XT_CLOSE && strcmp(k.name, "navmap") == 0) break;
        if (!in_map) continue;
        if (k.kind == XT_OPEN && strcmp(k.name, "navpoint") == 0 && !k.selfclose) depth++;
        else if (k.kind == XT_CLOSE && strcmp(k.name, "navpoint") == 0) depth--;
        else if (k.kind == XT_OPEN && strcmp(k.name, "text") == 0 && !k.selfclose) { free(label); label = collect_text(&t, "text"); }
        else if (k.kind == XT_OPEN && strcmp(k.name, "content") == 0) {
            if (xml_attr(k.attrs, k.alen, "src", &attr)) add_toc_href(b, label, dir, attr.data, depth - 1);
            free(label); label = NULL;
        }
    }
    free(label); sb_free(&attr); free(dir); free(data);
    return b->ntoc > before;
}

int load_epub(rd_book *b, char *err, size_t errlen) {
    if (zip_open_mem(&b->zip, b->file, b->file_len) != 0) { seterr(err, errlen, "Not a valid EPUB (zip) file."); return -1; }

    /* 1. find the package document */
    char *opf = NULL;
    sbuf attr = {0};
    size_t n;
    unsigned char *container = zip_get(b, "META-INF/container.xml", &n);
    if (container) {
        xtok t; xtoken k;
        xml_init(&t, (const char *)container, n);
        while (xml_next(&t, &k) != XT_END)
            if (k.kind == XT_OPEN && strcmp(k.name, "rootfile") == 0 && xml_attr(k.attrs, k.alen, "full-path", &attr)) {
                opf = xstrdup(attr.data); break;
            }
        free(container);
    }
    if (!opf || zip_find(&b->zip, opf) < 0) {
        free(opf); opf = NULL;
        for (int i = 0; i < b->zip.n; i++) {
            size_t l = strlen(b->zip.e[i].name);
            if (l > 4 && strcasecmp(b->zip.e[i].name + l - 4, ".opf") == 0) { opf = xstrdup(b->zip.e[i].name); break; }
        }
    }
    if (!opf) { sb_free(&attr); seterr(err, errlen, "EPUB has no package (.opf) file."); return -1; }

    unsigned char *pkg = zip_get(b, opf, &n);
    if (!pkg) { free(opf); sb_free(&attr); seterr(err, errlen, "Could not read the EPUB package file."); return -1; }
    char *opfdir = path_dir(opf);

    /* 2. metadata, manifest, spine */
    mitem *man = NULL; int nman = 0, capman = 0;
    char **spine = NULL; int nspine = 0, capspine = 0;
    char *cover_id = NULL, *ncx_id = NULL;
    xtok t; xtoken k;
    xml_init(&t, (const char *)pkg, n);
    while (xml_next(&t, &k) != XT_END) {
        if (k.kind != XT_OPEN) continue;
        if (strcmp(k.name, "title") == 0 && !b->title && !k.selfclose) {
            char *s = collect_text(&t, "title");
            if (*s) b->title = s; else free(s);
        } else if (strcmp(k.name, "creator") == 0 && !b->author && !k.selfclose) {
            char *s = collect_text(&t, "creator");
            if (*s) b->author = s; else free(s);
        } else if (strcmp(k.name, "meta") == 0) {
            if (xml_attr(k.attrs, k.alen, "name", &attr) && strcmp(attr.data, "cover") == 0 &&
                xml_attr(k.attrs, k.alen, "content", &attr)) { free(cover_id); cover_id = xstrdup(attr.data); }
        } else if (strcmp(k.name, "item") == 0) {
            if (nman == capman) { capman = capman ? capman * 2 : 64; man = realloc(man, sizeof *man * (size_t)capman); }
            mitem m = {0};
            if (xml_attr(k.attrs, k.alen, "id", &attr)) m.id = xstrdup(attr.data);
            if (xml_attr(k.attrs, k.alen, "href", &attr)) m.path = path_resolve(opfdir, attr.data);
            if (xml_attr(k.attrs, k.alen, "media-type", &attr)) m.mtype = xstrdup(attr.data);
            if (xml_attr(k.attrs, k.alen, "properties", &attr)) m.props = xstrdup(attr.data);
            if (m.id && m.path) man[nman++] = m;
            else { free(m.id); free(m.path); free(m.mtype); free(m.props); }
        } else if (strcmp(k.name, "spine") == 0) {
            if (xml_attr(k.attrs, k.alen, "toc", &attr)) ncx_id = xstrdup(attr.data);
        } else if (strcmp(k.name, "itemref") == 0) {
            if (xml_attr(k.attrs, k.alen, "idref", &attr)) {
                if (nspine == capspine) { capspine = capspine ? capspine * 2 : 64; spine = realloc(spine, sizeof *spine * (size_t)capspine); }
                spine[nspine++] = xstrdup(attr.data);
            }
        }
    }
    free(pkg);

    /* 3. chapters, in spine order */
    for (int i = 0; i < nspine; i++) {
        mitem *m = NULL;
        for (int j = 0; j < nman; j++) if (strcmp(man[j].id, spine[i]) == 0) { m = &man[j]; break; }
        if (!m || chapter_for_path(b, m->path) >= 0) continue;
        unsigned char *html = zip_get(b, m->path, &n);
        if (!html) continue;
        chapter *c = book_add_chapter(b, m->path);
        char *dir = path_dir(m->path);
        html_to_chapter(b, c, (const char *)html, n, dir, NULL);
        free(dir); free(html);
    }
    if (b->nch == 0) {
        seterr(err, errlen, "This EPUB has no readable chapters (it may be DRM-protected).");
        for (int j = 0; j < nman; j++) { free(man[j].id); free(man[j].path); free(man[j].mtype); free(man[j].props); }
        for (int i = 0; i < nspine; i++) free(spine[i]);
        free(man); free(spine); free(cover_id); free(ncx_id); free(opfdir); free(opf); sb_free(&attr);
        return -1;
    }

    /* 4. table of contents: EPUB 3 nav first, then NCX */
    int have_toc = 0;
    for (int j = 0; j < nman && !have_toc; j++)
        if (man[j].props && strstr(man[j].props, "nav")) have_toc = parse_nav(b, man[j].path);
    if (!have_toc) {
        for (int j = 0; j < nman && !have_toc; j++) {
            int is_ncx = (ncx_id && strcmp(man[j].id, ncx_id) == 0) ||
                         (man[j].mtype && strcmp(man[j].mtype, "application/x-dtbncx+xml") == 0);
            if (is_ncx) have_toc = parse_ncx(b, man[j].path);
        }
    }

    /* 5. cover image */
    for (int j = 0; j < nman && !b->cover; j++)
        if (man[j].props && strstr(man[j].props, "cover-image")) b->cover = xstrdup(man[j].path);
    for (int j = 0; j < nman && !b->cover && cover_id; j++)
        if (strcmp(man[j].id, cover_id) == 0 && man[j].mtype && strncmp(man[j].mtype, "image/", 6) == 0)
            b->cover = xstrdup(man[j].path);
    for (int j = 0; j < nman && !b->cover; j++)
        if (man[j].mtype && strncmp(man[j].mtype, "image/", 6) == 0 && strcasestr(man[j].id, "cover"))
            b->cover = xstrdup(man[j].path);

    for (int j = 0; j < nman; j++) { free(man[j].id); free(man[j].path); free(man[j].mtype); free(man[j].props); }
    for (int i = 0; i < nspine; i++) free(spine[i]);
    free(man); free(spine); free(cover_id); free(ncx_id); free(opfdir); free(opf); sb_free(&attr);
    return 0;
}
