# Fonts

`benchmarks.svg` is rendered by
[`bench-svg`](https://github.com/unk-404/benchmark_svg) with **Rounded Mplus 1c**.
The tool converts the TTF to SVG glyph outlines, so GitHub does not need to load
or install the font.

- Source: https://github.com/google/fonts/tree/main/ofl/mplusrounded1c
- Copyright: Copyright 2016 The Rounded M+ Project Authors.
- License: SIL Open Font License 1.1 (`OFL.txt`)
- `MPLUSRounded1c-Regular.ttf`: passed to `bench-svg` via `--font-file`; it is
  kept for local/CI rendering but excluded from the pub package.

The kaomoji `(◕‿◕)♡` is rendered with the platform emoji font
(`Segoe UI Emoji` / `Apple Color Emoji` / `Noto Color Emoji`) so the custom font
cannot distort it.
