/*
 * Folio reading engine — public C API.
 *
 * Everything about a book (container parsing, markup → styled text blocks,
 * table of contents, images, full-text search) lives behind this header.
 * The SwiftUI front end only ever sees these functions.
 *
 * Threading: rd_open() parses the whole book up front. After it returns,
 * every function here is read-only and safe to call from any thread.
 */
#ifndef FOLIO_READER_H
#define FOLIO_READER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Block types */
#define RD_P      0   /* paragraph            */
#define RD_H1     1   /* heading, level 1     */
#define RD_H2     2   /* heading, level 2     */
#define RD_H3     3   /* heading, level 3-6   */
#define RD_QUOTE  4   /* block quote          */
#define RD_PRE    5   /* preformatted / code  */
#define RD_LI     6   /* list item            */
#define RD_HR     7   /* scene break / rule   */
#define RD_IMG    8   /* image; text = resource path for rd_resource() */

/* Inline style bits (rd_span.style) */
#define RD_STYLE_ITALIC 1
#define RD_STYLE_BOLD   2
#define RD_STYLE_CODE   4

/* Search flags */
#define RD_SEARCH_MATCH_CASE 1  /* exact case and accents                  */
#define RD_SEARCH_WHOLE_WORD 2  /* match only on word boundaries           */
#define RD_SEARCH_ALL_WORDS  4  /* every word somewhere in the same block  */

typedef struct rd_book rd_book;

/* A styled run inside a block. Offsets are UTF-8 byte offsets into text. */
typedef struct {
    uint32_t start;
    uint32_t length;
    int32_t  style;
} rd_span;

typedef struct {
    int32_t        type;
    const char    *text;       /* UTF-8, NUL-terminated */
    uint32_t       text_len;   /* bytes, without the NUL */
    const rd_span *spans;
    int32_t        span_count;
} rd_block;

/* A search hit. offset/length are UTF-8 byte offsets into the block text. */
typedef struct {
    int32_t  chapter;
    int32_t  block;
    uint32_t offset;
    uint32_t length;
} rd_hit;

/* Open .epub, .txt, .md/.markdown, .html/.htm/.xhtml. NULL on failure,
   with a human-readable reason written to err. */
rd_book    *rd_open(const char *path, char *err, size_t errlen);
void        rd_close(rd_book *b);

const char *rd_title(const rd_book *b);
const char *rd_author(const rd_book *b);
const char *rd_format(const rd_book *b);      /* "EPUB", "Text", "Markdown", "HTML" */
uint64_t    rd_word_count(const rd_book *b);

int32_t     rd_chapter_count(const rd_book *b);
const char *rd_chapter_title(const rd_book *b, int32_t ch);
uint32_t    rd_chapter_text_len(const rd_book *b, int32_t ch);
/* Returns the number of blocks and points *out at an array owned by the book. */
int32_t     rd_chapter_blocks(const rd_book *b, int32_t ch, const rd_block **out);

int32_t     rd_toc_count(const rd_book *b);
const char *rd_toc_title(const rd_book *b, int32_t i);
int32_t     rd_toc_chapter(const rd_book *b, int32_t i);
int32_t     rd_toc_block(const rd_book *b, int32_t i);
int32_t     rd_toc_depth(const rd_book *b, int32_t i);

/* Raw bytes of an image or other resource (path from an RD_IMG block).
   Free with rd_free(). */
unsigned char *rd_resource(const rd_book *b, const char *path, size_t *len);
/* Cover image bytes if the book declares one (or the first image). */
unsigned char *rd_cover(const rd_book *b, size_t *len);
void           rd_free(void *p);

/* Full-text search. Folds case, accents, smart quotes, dashes and ligatures
   unless RD_SEARCH_MATCH_CASE. Writes up to max hits in reading order and
   returns how many were written. */
int32_t rd_search(const rd_book *b, const char *query, int32_t flags,
                  rd_hit *out, int32_t max);

#ifdef __cplusplus
}
#endif
#endif
