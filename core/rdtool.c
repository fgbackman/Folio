/* rdtool — command-line front end to the Folio engine (handy for testing books).
 *
 *   rdtool book.epub              summary + table of contents
 *   rdtool book.epub -c 3         print chapter 3 as text
 *   rdtool book.epub -s "query"   search (add -w whole words, -a all words, -m match case)
 */
#include "reader.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *TYPES[] = {"P", "H1", "H2", "H3", "QUOTE", "PRE", "LI", "HR", "IMG"};

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: rdtool FILE [-c N] [-s QUERY [-w] [-a] [-m]]\n"); return 2; }
    int chapter = -1, flags = 0; const char *query = NULL;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-c") && i + 1 < argc) chapter = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) query = argv[++i];
        else if (!strcmp(argv[i], "-w")) flags |= RD_SEARCH_WHOLE_WORD;
        else if (!strcmp(argv[i], "-a")) flags |= RD_SEARCH_ALL_WORDS;
        else if (!strcmp(argv[i], "-m")) flags |= RD_SEARCH_MATCH_CASE;
    }
    char err[256];
    rd_book *b = rd_open(argv[1], err, sizeof err);
    if (!b) { fprintf(stderr, "error: %s\n", err); return 1; }

    if (query) {
        rd_hit hits[500];
        int n = rd_search(b, query, flags, hits, 500);
        printf("%d hit(s) for \"%s\"\n", n, query);
        for (int i = 0; i < n; i++) {
            const rd_block *blocks;
            rd_chapter_blocks(b, hits[i].chapter, &blocks);
            const rd_block *blk = &blocks[hits[i].block];
            printf("  [%d:%d] …%.*s[%.*s]%.*s…\n", hits[i].chapter, hits[i].block,
                   (int)(hits[i].offset < 30 ? hits[i].offset : 30), blk->text + hits[i].offset - (hits[i].offset < 30 ? hits[i].offset : 30),
                   (int)hits[i].length, blk->text + hits[i].offset,
                   30, blk->text + hits[i].offset + hits[i].length);
        }
    } else if (chapter >= 0) {
        const rd_block *blocks;
        int n = rd_chapter_blocks(b, chapter, &blocks);
        printf("== %s (%d blocks)\n", rd_chapter_title(b, chapter), n);
        for (int i = 0; i < n; i++) {
            printf("%-5s %s\n", TYPES[blocks[i].type], blocks[i].text);
            for (int s = 0; s < blocks[i].span_count; s++)
                printf("      span %u+%u style %d: \"%.*s\"\n", blocks[i].spans[s].start, blocks[i].spans[s].length,
                       blocks[i].spans[s].style, (int)blocks[i].spans[s].length, blocks[i].text + blocks[i].spans[s].start);
        }
    } else {
        size_t clen = 0;
        unsigned char *cover = rd_cover(b, &clen);
        printf("Title:    %s\nAuthor:   %s\nFormat:   %s\nWords:    %llu\nChapters: %d\nCover:    %zu bytes\n",
               rd_title(b), rd_author(b), rd_format(b), (unsigned long long)rd_word_count(b),
               rd_chapter_count(b), clen);
        rd_free(cover);
        for (int i = 0; i < rd_chapter_count(b); i++) {
            const rd_block *blocks;
            printf("  ch %2d  %-40s %d blocks, %u bytes\n", i, rd_chapter_title(b, i),
                   rd_chapter_blocks(b, i, &blocks), rd_chapter_text_len(b, i));
        }
        printf("Contents (%d):\n", rd_toc_count(b));
        for (int i = 0; i < rd_toc_count(b); i++)
            printf("  %*s%s  → ch %d, block %d\n", rd_toc_depth(b, i) * 2, "", rd_toc_title(b, i),
                   rd_toc_chapter(b, i), rd_toc_block(b, i));
    }
    rd_close(b);
    return 0;
}
