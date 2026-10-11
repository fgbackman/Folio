# Folio

An ereader for Apple Silicon Macs (macOS 14+). The reading engine is C; the interface is SwiftUI.

## Build and run

You need the Xcode command line tools (`xcode-select --install`).

```bash
cd Folio
./build.sh            # builds build/Folio.app and build/rdtool
./build.sh --run      # build and launch
./build.sh --install  # build, copy to /Applications, launch
```

Or open `Folio.xcodeproj` in Xcode and press Run: it builds the Release app into `build/Release/Folio.app` and launches it.

`Samples/` has a few small books to try (EPUB 3, EPUB 2, a Gutenberg-style text file, Markdown).

Signing is ad-hoc by default. To sign with your Developer ID:

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh --install
```

## What it does

**Formats:** EPUB 2 and 3 (table of contents from nav or NCX, inline images), PDF, plain text (Project Gutenberg headers stripped, chapters detected, `_italics_` honoured), Markdown, and single-file HTML. DRM-protected EPUBs can't be opened.

**PDFs, two ways (⇧⌘P):** a PDF opens in its original pages, and one keystroke turns it into reflowed text in your own font, size and theme — and back, at the same place. Contents, search, bookmarks and progress work in both. The text is pulled out once (running heads and page numbers dropped, paragraphs rejoined, chapters taken from the PDF's outline or its headings) and kept in `~/Library/Application Support/Folio/Converted`. A scanned PDF with no text layer can only be read in its original pages.

**Find free books (⇧⌘O):** one search asks Project Gutenberg, Standard Ebooks, the Internet Archive, Open Library, Wikisource and arXiv together. Get a book and it is downloaded into `~/Library/Application Support/Folio/Books` and put on your shelf with a cover of its own.

**Library:** drag books onto the window or the Dock icon, or press ⌘O. Every cover is painted by the app, never taken from the book. The colours and drifting mist come from the title; the sky over them is real:

- **A real piece of sky** for each book — 200 of them, and the shelf gives every book a different one: all 88 constellations, 53 asterisms (the Big Dipper, the Teapot, Orion's Belt, the Summer Triangle…) and 59 fields around deep-sky objects and notable places (the Pleiades, the Galactic Centre, the Hubble Deep Field, the direction Voyager 1 is leaving in…). Stars are from the HYG catalogue: true positions, brightnesses and colours (from each star's B–V index). Stars shift by their real distances, so nearby Sirius sways while far-off Deneb barely moves. The figure is drawn faintly; each bookmark lights one more line of it (seven complete it).
- **The Milky Way** from its real outline (Great Rift and Coalsack included) and the **zodiacal light** along the ecliptic.
- **Deep-sky objects drawn after their real structure**: the Orion Nebula's teal heart, the Pillars of Creation, the Ring, Cat's Eye, Helix and Dumbbell nebulae, the Crab with its pulsar, the Veil, Andromeda with M32 and M110, the Whirlpool, the Sombrero, M87 and its jet, the Antennae, the Horsehead, the Pleiades' blue dust, Sagittarius A* as the Event Horizon Telescope saw it, PSR B1919+21 pulsing at its true 1.337 s period, and more.
- **Tonight's sky**: the Moon at its real phase (with earthshine on a crescent), the planets wherever they really are, and meteors from the showers active tonight, flying out of their real radiants at their real speeds — fast Orionids short and green with glowing trains, slow Draconids long and golden.
- **Real events**: eclipses on their real dates, and replays of famous ones (Eddington's 1919 eclipse, the 2017 and 2024 American eclipses, the corona shaped by the solar cycle; blood moons with the turquoise ozone fringe); great comets (Hale–Bopp, NEOWISE, McNaught's striae, Tsuchinshan–ATLAS's anti-tail) with physically correct ion and dust tails; historic supernovae and novae where they appeared (1054, Tycho's, Kepler's, SN 1987A); variable stars on their real light curves (Algol's eclipses, Mira, Betelgeuse's Great Dimming).
- **Aurora** on the polar constellations, coloured by real emission lines (green and red oxygen, violet nitrogen) and as strong as NOAA's live planetary K-index, checked hourly.
- **Your reading progress as an orbit**: a real planet or Halley's Comet on its true ellipse; Kepler's second law decides where you are, so equal reading sweeps equal areas.
- **Hover a cover** and the pointer becomes a gravitational lens (the point-mass lens equation bends the stars into arcs and an Einstein ring), with a caption naming what's under it — a star's distance and the year its light left, a nebula's story, tonight's showers and planets.

The covers animate slowly, drawn on the GPU with Metal; they pause whenever Folio isn't the front app. Turn the animation off under Settings › Library › Animate covers (they also stay still when Reduce Motion is on). Type in the library field to filter; press Return to search inside every book.

**Search (⌘F):** full-text search across the whole book, ignoring case, accents (é = e, ß = ss, Greek and Cyrillic too), curly quotes, dashes and ligatures. Options: Aa (exact case and accents), Whole words, All words (every word in the same paragraph, any order). Results are grouped by chapter and highlighted in the text. ⌘G / ⇧⌘G step through matches.

**Reading:** contents sidebar that tracks where you are, bookmarks (⌘D), nine fonts, six themes (Paper, Sepia, Sage, Night, Midnight, Glass), size, line spacing and column width. Progress and time left at the bottom; your place is remembered per book.

**Floating book (⇧⌘F):** a borderless window that is only the page — no title bar, no frame. Move the pointer to the top edge for controls (chapter, text size, keep-on-top pin, close); drag that edge to move it; resize from the bottom-right corner; Esc returns to the main window. It can have its own theme, text size and page opacity (Settings › Floating book).

**Dock and menu bar:** the Dock icon's menu has recent books, Float Book and Next Chapter. The menu bar book icon shows what you're reading and how far in, and offers the same actions. Closing the window keeps Folio running in the menu bar.

## Keyboard

| Action | Keys |
|---|---|
| Open book | ⌘O |
| Find free books | ⇧⌘O |
| Original pages / reflowed text (PDF) | ⇧⌘P |
| Find in book / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Previous / next chapter | ⌘[ / ⌘] |
| Bookmark | ⌘D |
| Bigger / smaller text | ⌘= / ⌘- |
| Float book / return | ⇧⌘F, Esc |
| Back to library | ⇧⌘L |

## Layout

```
core/      C engine — zip + inflate, XML/HTML tokenizer, EPUB/text/Markdown loaders,
           styled-block builder, folding full-text search; reader.h is the whole API
core/sky.c Sky engine — Sun, Moon, planets (JPL elements), meteor showers, eclipses, Kepler's equation;
           skydata.c holds the star, constellation, Milky Way and deep-sky data of the first 42 skies,
           skydata2.c the other 158 (generated by tools/skygen.py from the catalogues named below)
App/       SwiftUI app — Book.swift wraps the C API; Sky.swift wraps the sky engine;
           EtherealCover.swift and CoverPainter.swift paint the still part of the covers;
           CoverScene.swift lays out what moves, and CoverMetal.swift and CoverShaders.swift
           draw it on the GPU (the shaders are compiled at launch, so there is no Metal build step);
           PDFBook.swift reflows a PDF's text and OriginalPages.swift shows its pages;
           OpenLibraries.swift searches the free libraries and DiscoverView.swift is its window
tools/     skygen.py and skyfields.py — build core/skydata2.c
Resources/ Info.plist, AppIcon.icns
build.sh   clang + swiftc build into build/Folio.app
```

`build/rdtool` is a command-line front end to the engine, handy for checking a book:

```bash
build/rdtool book.epub                 # metadata, chapters, contents
build/rdtool book.epub -c 3            # chapter 3 as styled blocks
build/rdtool book.epub -s "query" -w   # search (-w whole words, -a all words, -m match case)
```

Library data lives in `~/Library/Application Support/Folio/library.json`. Books you add yourself stay where they are on disk; if you move one, the library marks it missing. (Set `FOLIO_HOME` to another folder to try things out on a separate shelf.)

## Sky data

- Stars: [HYG database](https://github.com/astronexus/HYG-Database) v4.1 by David Nash, CC BY-SA 4.0.
- Constellation and asterism figures, Milky Way outline, deep-sky positions: [d3-celestial](https://github.com/ofrohn/d3-celestial) by Olaf Frohn, BSD 3-Clause.
- Planets: JPL "Approximate Positions of the Planets" (E. M. Standish). Moon: low-precision series from the Astronomical Almanac.
- Meteor showers: IMO working list. Eclipse dates: NASA eclipse predictions (Espenak). Live geomagnetic activity: NOAA Space Weather Prediction Center planetary K-index.
