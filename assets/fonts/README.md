# Fonts

`benchmarks.svg` uses **Rounded Mplus 1c** for its text, converted to SVG
outlines so GitHub does not need to load or install a font.

- Source: https://github.com/google/fonts/tree/main/ofl/mplusrounded1c
- Copyright: Copyright 2016 The Rounded M+ Project Authors.
- License: SIL Open Font License 1.1 (`OFL.txt`)
- `mplus_rounded1c_glyphs.json`: ASCII + `·`/`±` subset generated from the TTF
  with fontTools; it contains advances and path outlines, not the full font.

The kaomoji `(◕‿◕)♡` intentionally uses the platform emoji font
(`Segoe UI Emoji` / `Apple Color Emoji` / `Noto Color Emoji`) so the custom
font cannot distort it.

The TTF is kept in the repository for regeneration but is excluded from the
pub package; the generated JSON and the OFL license are included.
