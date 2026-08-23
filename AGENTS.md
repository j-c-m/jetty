# Agent guide — jetty

Swift 6 + C macOS terminal (`dev.jetty.app`). Locked 16-byte `Cell`. `TERM=xterm-256color`. Do not wrap Ghostty. Do not grow linux16term. Do not densify the cell for benches.

## Commands

```
swift test --disable-sandbox
swift test -c release --disable-sandbox
swift build -c release --disable-sandbox
```

Targeted: `--filter ScreenTests.testScrollRegionParseCost` (always **release** for timings).

vtebench: `/Users/jmiller/dev/vtebench` (`./target/release/vtebench`), run **inside** a jetty window.

## Performance (do not regress)

Parse/PTY drain is a product requirement. A feature that is idle on the ASCII `y\n` path must not add per-cell work on scroll or print.

**Incident (PR 7):** `fill_row` / `store_ascii_cells` / `stamp_cell` walked every cell to retain/release grapheme and rare refs. vtebench `scrolling` is `y\n` and never uses those pools. Result: scrolling 26ms → 64ms, regions 16ms → 58ms.

**Rule:** `jt_scr.pool_cells` is the live count of cells with a grapheme or rare `extra`. When it is 0:

- `fill_row` must not scan the row (lazy `erased=1` only)
- `store_ascii_cells` must not `release_cells`
- `stamp_cell` is a plain assign

Do not put new per-cell retain, hash, width, or memmove on `jt_scr_index` / `fill_row` / ASCII `print_run` unless a bench shows it is free. ASCII `print_run` of one byte uses the store path, not `print_scalar` (IRM still uses `print_scalar`).

**Canary (release, 105×35, 1 MiB samples):**

| bench | expect |
| --- | ---: |
| scrolling | ~27ms |
| scrolling_*_region | ~18ms |
| scrolling_fullscreen | ~16ms |
| dense_cells / medium_cells | ~7 / ~5ms |

In-process: `ScreenTests.testScrollRegionParseCost` / `testPrintRunCost` stderr. Release `y\n` 200k alt should stay ~5ms; 1 MiB `y\n` ~16ms; 10k full-width lines ~1ms. A 2× jump on those is a regression — fix before commit.

Further `y\n` wins that skip BCE-filling unread cells on a new row are a design change (partial erase). Do not sneak them in.

## Other locks

- 16-byte `Cell`, colors tagged per channel. No Ghostty style table.
- Ligatures default `programming`; letters stay cell-boxed. ExtraBold is SGR 1.
- Tests travel with the code they prove.
