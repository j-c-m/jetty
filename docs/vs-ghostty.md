# Jetty vs Ghostty

Ghostty is the sequence spec and the daily-driver bar. Jetty copies dispatch and terminfo shape from Ghostty (`src/terminal/`), ported to C. It does not link `libghostty`, Zig, or `ghostty.h`.

Observed on the same Mac, same font size, same `y\n` / neovim-tmux load: Jetty is a few percent faster on parse and scroll (about 3–10%), and about twice as efficient in combined CPU + GPU. The rest of this note is why that happens, and what Jetty does not try to be.

## Product

| | Ghostty | Jetty |
| --- | --- | --- |
| OS | macOS, Linux, (Windows later) | macOS 14+, Apple Silicon |
| `TERM` | `xterm-ghostty` | stock `xterm-256color` |
| Layout | windows, tabs, splits | windows only |
| Graphics | Kitty images, custom shaders, background images | cells, sprites, emoji atlas |
| Chrome | inspector, command palette, quick terminal, settings | menus + `~/.config/jetty/config` |
| Ligatures | font `liga` / `calt` on shaped runs | default `programming` (table hit); `on` shapes each run; letters stay cell-boxed |
| SGR 1 | bold face | ExtraBold face |
| Keyboard | full `Action` union, Kitty keyboard optional | host keybinds + xterm encode |

Jetty is a lightweight xterm. Tabs, splits, Kitty graphics/keyboard, Sixel, ImGui inspector, and other OS ports stay out. AppleScript command names match Ghostty for windows and terminals.

## Machine

**Cell.** Ghostty stores an 8-byte packed `Cell` (`page.zig`) plus a `style_id` into a per-page style table. Color, bold, underline, and reverse live in that table. A new SGR intern hashes and interned-inserts. Jetty stores a locked 16-byte inline `Cell`: codepoint, tagged `fg`/`bg`, attrs, rare id. Mixed SGR (`38;5;n` + `48;2;r;g;b`) is in the cell. Zero bits are the empty default. There is no style table.

**Parser / grid.** Both SIMD-scan the VT stream. Ghostty’s `libghostty-vt` has NEON in the parse path, then writes page-backed rows, grapheme maps, hyperlink sets, and Kitty placeholders. Jetty’s VT is C: also NEON ASCII `print_run`, Hoehrmann UTF-8, `try_fast_csi`, circular live origin. Scrollback is a row ring, 16K-aligned slabs. History pages are not rewritten on live `index`. The few-percent win is not parse SIMD.

**Graphemes.** Both intern multi-codepoint clusters. Jetty keeps `jt_scr.pool_cells`: the count of cells that hold a grapheme or rare `extra`. When it is 0 (the `y\n` path), `fill_row` does not scan, `store_ascii_cells` does not `release_cells`, and `stamp_cell` is a plain assign.

**GPU.** Ghostty’s Metal path uses an `IOSurfaceLayer` (not `CAMetalLayer` drawables): each in-flight `FrameState` has its own IOSurface-backed `MTLTexture`, plus copy-forward / span blit and extra passes for images, shaders, and ink-bearing glyphs. Jetty is an `MTKView` of instanced quads: opaque R8 glyphs with blending **off**, a blended ink pass only for ligature overflow and BGRA emoji, then overlays (underline, cursor, progress). Instances are 32 bytes. Clean rows memcpy from the last presented ring slot; they are not re-expanded. `maximumDrawableCount = 2` is a present-latency cap on the layer, not a Ghostty contrast.

**Glyph cache.** Ghostty rasters a tight bbox and stores left/top bearings (`font/Glyph.zig` `offset_x` / `offset_y`). Paint is an ink-bearing quad: origin = cell + bearing, size = glyph pixels. A constraint pass (`fit` / `cover` / `stretch` / Nerd `fit_cover1`) remaps size and alignment per glyph. The atlas is a bag of variable rectangles.

Jetty rasters **into the cell**. `GlyphAtlas.rasterizeGray` allocates `cellW × cellH` (or `2×cellW` for wide). `CTLineDraw` at `(center, baseline)`. Coverage is `max(alpha, r)`. The atlas UV is that full tile. The GPU draws a cell-sized quad, blending **off**: background is the instance `bg`, ink is the R8. Sprites (`SpriteFace.covers`) fill the same box and win before the font, so box-drawing meets cell edges without a Nerd constraint rule.

Cache key for letters is `(scalar, bold, italic, wide)` plus a grapheme-cluster hash. One codepoint → one cell-sized tile. Zoom or font change rebuilds the atlas. Idle frames do not reshape and do not re-raster.

The cost: italic and over-wide Nerd icons **clip** to the box. Ghostty’s bearing quads do not.

**Shaping.** Ghostty shapes text runs (HarfBuzz / Core Text) as the normal letter path. `liga` / `calt` apply to whatever the font ligates. Every row of code is a shaping job unless a higher cache hits.

Jetty does not shape letters. `ligatures = off`: no run hash, no `CTLine` of a span. Default `programming`: longest-first ASCII table (`ProgrammingLigatures`, JetBrains Mono `calt` list). Only a table hit (`=>`, `!=`, `<!--`, …) goes through `ShaperCache` (512×8 buckets). `hello` stays two-path cell tiles. `ligatures = on` shapes each run, then still paints 1:1 / `xOffset≈0` cells with the letter atlas so `a` does not change.

`on` is almost as fast as `programming`. Cache hits skip `CTLine`. Non-ligated cells stay the letter atlas. Only cmap-mismatch spans take coverage ink. Ghostty shapes every run as the letter path. Jetty with `on` is not slower than that.

A ligature that actually merges glyphs (cmap mismatch, JetBrains spacer + liga at `xOffset≈0`) is one **N-cell** R8 coverage tile (`cells * cellW`) over per-cell backgrounds, blend-on. It is not a 2-cell mix tile (that would bake two backgrounds). The `y\n` canary never enters this path.

## Throughput (about 3–10%)

vtebench `scrolling` is `y\n`. That path never hits grapheme or rare pools.

Ghostty still walks a page cell, a `style_id`, and page metadata on every print and scroll. Jetty’s ASCII `print_run` of one byte is the store path. `index` / `fill_row` do not memmove, hash, or retain when `pool_cells == 0`. The C scanner takes a fast CSI prong when the sequence is short. Parse yields to draw on a 1 ms budget so the GPU thread is not starved. Parse NEON is on both sides.

That is a small constant-factor win on a path that is already memory-bound. It shows up as a few percent on 1 MiB `y\n` and the region/fullscreen scroll benches, not as a different algorithm.

Canaries (release, 105×35, 1 MiB): scrolling ~27 ms, region ~18 ms, fullscreen ~16 ms. A 2× jump on those is a Jetty regression. Head-to-head vs Ghostty on the same dump is the 3–10% band.

## Efficiency (about 2× CPU + GPU)

Throughput is “how fast can we eat bytes.” Efficiency is “how much silicon a live session burns.”

A neovim or tmux window at 60 Hz is mostly idle cells. Ghostty still has a heavy frame: IOSurface present, style resolve, full glyph pipeline, plus host work for splits/inspector if those are open.

Jetty’s idle frame is small:

1. **Dirty-row skip.** C `dirty[]` + `damage_gen`. A status-line change expands that row. The rest of the instance buffer is memcpy from the last presented slot. Follow-on math: 5K ~32k cells × 80 B × 60 Hz was ~150 MB/s of instance traffic before skip and compact. After: idle is about one row; a full `cat` at 32-byte stride is ~60 MB/s.
2. **32-byte instances, blend-off glyphs.** The common letter pass is opaque nearest-filter R8 over a cell-sized atlas tile. Ghostty’s ink-bearing, blended, shaped glyphs cost more fragment time per cell (variable bbox, bearings, often alpha blend). Jetty only blends ligature overflow and emoji.
3. **No shape on the letter path.** A neovim row is atlas lookups of cell-boxed tiles, not HarfBuzz. `programming` `CTLine`s only table spans. `on` shapes each run then paints the same tiles; it is almost as fast as `programming`. Ghostty shapes runs as the default.
4. **No style intern on idle.** The grid already holds paint-ready colors. OSC 4 / palette change invalidates GPU skip once; it does not hash styles every frame.
5. **No extra compositor.** No Kitty image atlas, no shadertoy, no background image, no ImGui inspector. That work is not “optimized away”; it is not in the process.
6. **macOS + Apple Silicon only.** One Metal path, no GTK/Vulkan/Win32 tax on the hot threads.

Together that is why Activity Monitor / powermetrics show roughly half the CPU+GPU for the same editor session, while vtebench only moves a few percent. The byte-eating path was already tight. The frame path was fat in Ghostty because the product is larger.

## Honesty

Jetty is slower or incomplete where Ghostty is a different product: Kitty graphics, tabs/splits layout, ink-bearing italic, Linux. Full ligatures (`ligatures = on`) are not in that list: they are almost as fast as default `programming`, and not slower than Ghostty’s shaped runs. Cell-boxed letters clip italic and some Nerd icons; Ghostty’s bearing + constraint path does not. Do not advertise `xterm-kitty`. Do not claim a smaller cell; Ghostty’s 8-byte cell is denser RAM and a more expensive mutate. Jetty pays 16 bytes to keep print and paint on one struct.

Sequence parity is “Ghostty as spec.” Paint and host chrome are Jetty’s.
