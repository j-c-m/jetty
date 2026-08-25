# Jetty vs Ghostty: CPU and GPU

Date: 2026-08-25

Source: Jetty `docs/vs-ghostty.md` plus the two renderers. No Ghostty
code was changed. The goal is the ranked list of Jetty wins that would
cut Ghostty CPU and GPU on a live neovim/tmux session.

Jetty’s ~2× CPU+GPU win on that session is almost all **frame cost**,
not parse. vtebench `y\n` is only 3–10%. Ghostty’s byte path is already
tight. The frame path still does a full-screen, blended, color-converted
redraw on every wakeup.

## Why the gap is 2×, not 3–10%

Throughput is “how fast we eat PTY bytes.” Both SIMD-scan. Jetty’s extra
few percent is `pool_cells == 0` (no grapheme retain on ASCII), circular
origin (no page rewrite on `index`), and a 16-byte inline `Cell` with no
style intern. That is memory-bound. It will not halve Activity Monitor.

Efficiency is “silicon a 60 Hz editor session burns.” That session is
mostly **idle cells plus one dirty status/cursor row**. Ghostty still:

- rebuilds GPU buffers for the **whole** grid
- draws **every pixel** twice (fullscreen bg + blended glyphs)
- presents through **three IOSurface-backed BGRA targets** in Display P3

Jetty expands the dirty rows, memcpy’s the rest, then draws **one opaque
cell pass** into an `MTKView` drawable.

---

## 1. One opaque cell pass (largest GPU cut)

Ghostty’s Metal frame is always at least three draws:

1. Fullscreen `bg_color` triangle
2. Fullscreen `cell_bg` triangle (blending **on**)
3. Instanced `cell_text` (blending **on**, ink-bearing quads)

```1777:1857:src/renderer/generic.zig
            {
                var pass = frame_ctx.renderPass(&.{.{
                    ...
                    .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                }});
                ...
                } else {
                    pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_color,
                        ...
                    });
                }
                ...
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_bg,
                    ...
                });
                ...
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_text,
                    ...
                    .draw = .{
                        .type = .triangle_strip,
                        .vertex_count = 4,
                        .instance_count = fg_count,
                    },
                });
```

`cell_bg` runs **once per screen pixel**. Default
`window-colorspace = srgb`, but the IOSurface is Display P3, so every
fragment linearizes and does an sRGB→P3 matrix. Ghostty already notes
the waste:

```490:504:src/renderer/shaders/shaders.metal
  uchar4 cell_color = cells[grid_pos.y * uniforms.grid_size.x + grid_pos.x];
  // TODO: ... convert all of the bg colors, so we don't waste
  //       a bunch of work converting the cell color in every
  //       fragment of each cell.
  return load_color(
    cell_color,
    uniforms.use_display_p3,
    uniforms.use_linear_blending
  );
```

`cell_text` then blends a **tight bbox** at cell+bearing. Four vertices
per glyph. Each vertex does `load_color` on fg, cell bg, and global bg.
Premultiplied blend ROP on every coverage sample.

Jetty: one instanced pass of **cell-sized** quads,
`isBlendingEnabled = false`. Coverage is `mix(bg, fg, atlas.r)` in the
shader. Blend only for ligature overflow and emoji.

```42:46:Sources/Jetty/Render/TerminalRenderer.swift
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = false
```

```295:311:Sources/Jetty/Render/TerminalRenderer.swift
        float cover = saturate(a);
        float3 rgb = mix(in.bg.rgb, in.fg.rgb, cover);
        return float4(rgb, mix(in.bg.a, 1.0, cover));
```

That is the bulk of the GPU 2×. Same pixel count, far less fragment math,
no blend unit, no overdraw from ink that sticks out of the cell.

**Ghostty-shaped version that keeps italic:** keep bearing quads, but:

- bake linearized/P3 colors **once per cell**, not per fragment
- draw bg as **cell-sized opaque quads** (or skip `cell_bg` for
  default-bg cells)
- blend **off** for glyphs whose bbox is inside the cell; blend on only
  for overflow (italic, combining, Nerd)

Full Jetty “letters are cell tiles” clips italic and some Nerd icons. Do
not take that unless you accept the look.

---

## 2. Stop the IOSurface + Display P3 present tax (GPU + compositor)

Ghostty is not a `CAMetalLayer` drawable. Each of **three** in-flight
`FrameState`s owns a full-screen IOSurface-backed `MTLTexture`. Present
is `CALayer.contents = IOSurface` on the main thread.

```54:60:src/renderer/metal/Target.zig
    const surface = try IOSurface.init(.{
        .width = @intCast(opts.width),
        .height = @intCast(opts.height),
        .pixel_format = .@"32BGRA",
        ...
        .colorspace = colorspace,  // Display P3
    });
```

```36:37:src/renderer/Metal.zig
/// Triple buffering.
pub const swap_chain_count = 3;
```

Costs:

- 3× screen-sized BGRA in GPU memory, rewritten every frame
- WindowServer treating `CALayer.contents` as a bitmap, not a Metal
  drawable
- Forced P3 output, so sRGB terminal colors convert in the shader
- `setSurface` retains, hops to main, size-checks, then sets contents

Jetty: `MTKView`, `framebufferOnly = true`, `maximumDrawableCount = 2`,
`bgra8Unorm`. GPU writes the drawable the compositor already owns.

This is the next GPU/memory-bandwidth win after the pass count. It is
macOS-specific. GTK/OpenGL would not get it. Resize jank and
“Apple-style” blending are why Ghostty chose IOSurface; Jetty accepted
nearest, integer pixels instead.

---

## 3. Dirty GPU skip, not only dirty CPU rebuild (CPU + GPU)

Ghostty already skips **CPU** rebuild of clean rows (`rebuildRow`
continues if `!dirty`). That is not Jetty’s win.

Then it throws it away:

```1744:1746:src/renderer/generic.zig
            try frame.uniforms.sync(&.{self.uniforms});
            try frame.cells_bg.sync(self.cells.bg_cells);
            const fg_count = try frame.cells.syncFromArrayLists(self.cells.fg_rows);
```

`sync` / `syncFromArrayLists` memcpy **the entire grid** into the next
triple-buffer slot. Then the GPU redraws **every pixel**.

`rebuildCells` also sets `cells_rebuilt = true` **unconditionally**,
even if every row was skipped:

```2776:2777:src/renderer/generic.zig
            // Update that our cells rebuilt
            self.cells_rebuilt = true;
```

So a neovim status line or a cursor blink: one dirty row on CPU, full
upload + full GPU frame.

Jetty: C `dirty[]` + `damage_gen`. Clean rows are `memcpy` from the last
**presented** ring slot. Idle is about one row. Their own math: before
skip, ~150 MB/s of 80-byte instances at 60 Hz; after, 32-byte stride and
one row.

```64:91:Sources/Jetty/Render/DirtySkip.swift
    /// `true` = expand the paint row; `false` = memcpy from the last presented slot.
    static func expandRows(...)
```

`src/renderer/cell.zig` already says the Contents layout exists “to
eliminate the overhead of rebuilding the GPU buffers each frame.” That
half is done. The upload and the draw are not.

**Without changing glyph look:**

- Do not set `cells_rebuilt` unless a row was actually rebuilt (or
  cursor uniforms changed).
- Upload only dirty row ranges.
- True GPU skip: blit the previous target, scissor to dirty rows.
  Triple-buffered IOSurface makes that annoying; that is another reason
  Jetty stayed on an instance ring.

That is the largest **CPU** cut that does not change text appearance.

---

## 4. Demand-driven present, not a focused CVDisplayLink (CPU)

Jetty’s view is paused:

```87:92:Sources/Jetty/Render/MetalTerminalView.swift
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        ...
            metalLayer.maximumDrawableCount = 2
```

Draw only on `needsDisplay` from PTY/cursor/scroll.

Ghostty, while focused and visible, runs `CVDisplayLink` and fires
`draw_now` every vsync:

```1194:1201:src/renderer/generic.zig
            if (self.visible and self.focused) {
                display_link.start() catch {};
            } else {
                display_link.stop() catch {};
            }
```

Idle path is a no-op (`presentLastTarget` is empty on Metal) but still:
DisplayLink callback → xev async → render thread → draw mutex →
`surfaceSize`. Cursor blink and any PTY byte then take the full GPU path
in (3).

Default `window-vsync = true`. Stopping the link when `cells_rebuilt` is
false, or matching Jetty’s setNeedsDisplay, is idle CPU for free.

---

## 5. Do not shape letters on the normal path (CPU on dirty rows)

Ghostty’s letter path is always a shaping job. Cache hits skip Core
Text/HarfBuzz, not the run walk:

```2833:2850:src/renderer/generic.zig
            var run_iter_opts: font.shape.RunOptions = .{
                .grid = self.font_grid,
                .cells = cells_slice,
                ...
            };
            var run_iter = self.font_shaper.runIterator(run_iter_opts);
```

`RunIterator.next` walks the row, hashes, splits on
style/font/selection. Then `renderGlyph` with Nerd
`fit`/`cover`/`stretch` and bearings.

Jetty does not shape `hello`. Atlas key is
`(scalar, bold, italic, wide)`. Default `programming` only `CTLine`s
table hits (`=>`, `!=`, …). Idle frames do not reshape or re-raster.

The shaper cache comment is blunt: shaping once accounted for **96% of
frame time**. Cache fixed the worst of it. The iterator + constraint +
bearing path is still paid on every dirty row (status line, prompt).

**Ghostty-shaped version:** if `font-feature` is empty and the row is
ASCII/Latin, skip the run iterator and do cmap + atlas like Jetty. Keep
shaping for `calt`/`liga`, Arabic, and marked clusters.

Taking Jetty’s cell-boxed raster (`CTLineDraw` into `cellW×cellH`,
nearest, integer `ox`/`oy`) is a **look** change: no subpixel position,
italic clips. Ghostty’s Core Text path is:

```485:488:src/font/face/coretext.zig
        context.setShouldSubpixelPositionFonts(ctx, true);
        ...
        context.setShouldSubpixelQuantizeFonts(ctx, false);
```

That is quality Ghostty wants. Skip shaping first; do not drop subpixel
unless you take win 1’s cell tiles.

---

## 6. Paint-ready cells (CPU write + paint, smaller than 1–5)

Ghostty cell is 8 bytes + `style_id` into a per-page intern table. SGR
hashes and inserts. Paint copies the page row, then `endUpdate`
denormalizes style runs into per-cell `Style` (~10% of `endUpdate` when
styled). Then `rebuildRow` resolves palette/bold/inverse/selection
again.

Jetty cell is 16 bytes: tagged `fg`/`bg` already in the cell. OSC 4/10/11
stay tagged until expand. No intern. Palette change invalidates GPU skip
once.

Do **not** densify Ghostty’s cell to 16 bytes to “win.” Jetty says
Ghostty’s 8-byte cell is denser RAM and a **more expensive mutate**. The
win is “paint does not hash.” Cheaper Ghostty version: keep the 8-byte
cell, but treat denormalized row styles as the GPU source of truth and
never re-resolve on a clean row (partially done via `applied_styles`).
Combined with (3), intern stays on the write path only.

ASCII `y\n` / `pool_cells` is a few percent throughput. Not the 2×.

---

## 7. Product surface (real, but not the neovim gap)

Jetty has no Kitty images, Shadertoy, background image, ImGui inspector,
tabs, or splits. Ghostty still **calls** `images.upload` / `images.draw`
three times per frame even when empty. Custom shaders add a full-screen
ping-pong at 8 ms if enabled.

A neovim-tmux window with defaults does not hit those. They explain some
of “Ghostty in Activity Monitor” if inspector/shaders/images are on.
They do not explain the 2× on the same editor session Jetty measured.

---

## Ranked, if the goal is Ghostty CPU+GPU

| Rank | Win | Silicon | Quality hit | Ghostty-shaped form |
| --- | --- | --- | --- | --- |
| 1 | Opaque cell pass + no per-fragment P3 | GPU, large | None if you keep bearings and only skip blend for in-cell glyphs | Bake colors; cell-quad bg; blend-off for in-cell ink |
| 2 | `CAMetalLayer` drawable, 2 buffers, sRGB unless asked | GPU + compositor | Lose IOSurface resize/P3 blending story | macOS-only; keep IOSurface as opt-in |
| 3 | Dirty GPU skip + dirty upload | CPU + GPU, large on idle TUIs | None | Fix `cells_rebuilt`; row-range `sync`; blit+scissor |
| 4 | Pause vsync when nothing changed | CPU idle | None | DisplayLink only while `cells_rebuilt` / blink / animation |
| 5 | Skip letter shaping when features off | CPU on dirty rows | None for ASCII | Gate `runIterator` on `font-feature` / script |
| 6 | Cell tiles + nearest + no subpixel | GPU extra | Clips italic/Nerd | Jetty-only look; do not take as default |
| 7 | Inline 16-byte cell | Small CPU, more RAM | Different machine | Keep 8-byte + intern; cache denorm |

**Do not chase:** parse SIMD, `pool_cells` on `y\n`, dropping
Kitty/shaders from the *binary* without dropping them from the *frame*
(empty draws are cheap; the three always-on cell passes are not).

The honest split from Jetty’s own note still holds: the byte path was
already tight; the frame path is fat because the product paints
ink-bearing, color-managed, IOSurface-presented glyphs every vsync.
Wins 1–4 are the ones that can move Ghostty toward that 2× without
becoming Jetty.
