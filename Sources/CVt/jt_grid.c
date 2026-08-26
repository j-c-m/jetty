#include "jt_vt.h"

#include <stdlib.h>
#include <string.h>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

enum { JT_GRID_ALIGN = 16384 };

static size_t grid_alloc_size(int32_t cols, int32_t grid_rows) {
    size_t n = (size_t)cols * (size_t)grid_rows * sizeof(Cell);
    size_t a = (size_t)JT_GRID_ALIGN;
    size_t rounded = (n + a - 1) / a * a;
    return rounded < a ? a : rounded;
}

static Cell *grid_alloc(int32_t cols, int32_t grid_rows) {
    void *p = NULL;
    if (posix_memalign(&p, (size_t)JT_GRID_ALIGN, grid_alloc_size(cols, grid_rows)) != 0)
        return NULL;
    return (Cell *)p;
}

static void default_tabs(uint8_t *t, int32_t cols) {
    for (int32_t i = 0; i < cols; i++)
        t[i] = (i > 0 && (i % 8) == 0) ? 1 : 0;
}

static void jt_palette_reset(uint32_t pal[256]) {
    /* Eighties Black (terminal-themes / ghosvt). Cube 16–255 stays xterm. */
    static const uint32_t ansi[16] = {
        0x111111, 0xEE4549, 0x59B259, 0xC86131,
        0x3773AF, 0xB259B2, 0x37AFAF, 0xCCCCCC,
        0x888888, 0xF2777A, 0x99CC99, 0xFFCC66,
        0x6699CC, 0xCC99CC, 0x66CCCC, 0xF2F0EC,
    };
    for (int i = 0; i < 16; i++) pal[i] = ansi[i];
    for (int r = 0; r < 6; r++) {
        for (int g = 0; g < 6; g++) {
            for (int b = 0; b < 6; b++) {
                uint32_t R = r == 0 ? 0 : (uint32_t)(r * 40 + 55);
                uint32_t G = g == 0 ? 0 : (uint32_t)(g * 40 + 55);
                uint32_t B = b == 0 ? 0 : (uint32_t)(b * 40 + 55);
                pal[16 + 36 * r + 6 * g + b] = (R << 16) | (G << 8) | B;
            }
        }
    }
    for (int i = 0; i < 24; i++) {
        uint32_t v = (uint32_t)(8 + 10 * i);
        pal[232 + i] = (v << 16) | (v << 8) | v;
    }
}

static void apply_pal_overlay(jt_scr *s) {
    for (int i = 0; i < 16; i++) {
        if (s->pal_overlay_mask & (uint16_t)(1u << i))
            s->palette[i] = s->pal_overlay[i] & 0x00FFFFFFu;
    }
}

static void jt_defaults_reset(jt_scr *s) {
    jt_scr_palette_reset(s);
    s->default_fg = COLOR_RGB | 0xCCCCCCu;
    s->default_bg = COLOR_RGB | 0x000000u;
    s->cursor_color = COLOR_DEFAULT;
}

void jt_scr_set_palette_overlay(jt_scr *s, const uint32_t rgb16[16], uint16_t mask) {
    if (!s) return;
    if (rgb16) memcpy(s->pal_overlay, rgb16, sizeof(s->pal_overlay));
    else memset(s->pal_overlay, 0, sizeof(s->pal_overlay));
    s->pal_overlay_mask = mask;
}

void jt_scr_palette_reset(jt_scr *s) {
    if (!s) return;
    jt_palette_reset(s->palette);
    apply_pal_overlay(s);
}

void jt_scr_palette_reset_index(jt_scr *s, int idx) {
    if (!s || idx < 0 || idx > 255) return;
    uint32_t tmp[256];
    jt_palette_reset(tmp);
    s->palette[idx] = tmp[idx];
    if (idx < 16) apply_pal_overlay(s);
}

static Cell blank_cell(const jt_scr *s) {
    Cell c;
    c.content = content_scalar(0x20, WIDE_NARROW);
    c.fg = s->pen.fg;
    c.bg = s->pen.bg;
    c.attrs = s->pen.attrs;
    c.extra = 0;
    return c;
}

static int32_t phys_y(const jt_buf *b, int32_t y) {
    return b->rowmap[y];
}

static Cell *row_at(jt_scr *s, int32_t y) {
    jt_buf *b = s->active;
    return b->grid + (size_t)phys_y(b, y) * (size_t)s->cols;
}

static const Cell *row_at_c(const jt_scr *s, int32_t y) {
    const jt_buf *b = s->active;
    return b->grid + (size_t)phys_y(b, y) * (size_t)s->cols;
}

static uint8_t *wrap_at(jt_scr *s, int32_t y) {
    jt_buf *b = s->active;
    return &b->wrap[phys_y(b, y)];
}

static uint8_t *dirty_at(jt_scr *s, int32_t y) {
    jt_buf *b = s->active;
    return &b->dirty[phys_y(b, y)];
}

static uint8_t *erased_at(jt_scr *s, int32_t y) {
    jt_buf *b = s->active;
    return &b->erased[phys_y(b, y)];
}

static Cell erased_blank(const jt_buf *b, int32_t py, Cell fallback) {
    if (b->erase && py >= 0 && py < b->grid_rows)
        return b->erase[py];
    return fallback;
}

static void fill_cells(Cell *row, int32_t n, Cell b) {
    if (n <= 0) return;
#if defined(__ARM_NEON)
    uint8x16_t v = vld1q_u8((const uint8_t *)&b);
    int32_t x = 0;
    for (; x + 8 <= n; x += 8) {
        vst1q_u8((uint8_t *)(row + x + 0), v);
        vst1q_u8((uint8_t *)(row + x + 1), v);
        vst1q_u8((uint8_t *)(row + x + 2), v);
        vst1q_u8((uint8_t *)(row + x + 3), v);
        vst1q_u8((uint8_t *)(row + x + 4), v);
        vst1q_u8((uint8_t *)(row + x + 5), v);
        vst1q_u8((uint8_t *)(row + x + 6), v);
        vst1q_u8((uint8_t *)(row + x + 7), v);
    }
    for (; x + 2 <= n; x += 2) {
        vst1q_u8((uint8_t *)(row + x), v);
        vst1q_u8((uint8_t *)(row + x + 1), v);
    }
    for (; x < n; x++) row[x] = b;
#else
    for (int32_t x = 0; x < n; x++) row[x] = b;
#endif
}

static void cell_retain(jt_scr *s, const Cell *c);
static void cell_release(jt_scr *s, Cell *c);
static void release_cells(jt_scr *s, Cell *row, int32_t n);

/* ASCII bytes → 16-byte cells. Last u32 is attrs (low half) + extra (high half). */
static void store_ascii_cells(jt_scr *s, Cell *dest, const uint8_t *p, size_t n,
                              uint32_t fg, uint32_t bg, uint16_t attrs, uint16_t extra) {
    if (s->pool_cells) release_cells(s, dest, (int32_t)n);
#if defined(__ARM_NEON)
    uint32x4_t vfg = vdupq_n_u32(fg);
    uint32x4_t vbg = vdupq_n_u32(bg);
    uint32x4_t vae = vdupq_n_u32((uint32_t)attrs | ((uint32_t)extra << 16));
    size_t k = 0;
    while (k + 16 <= n) {
        uint8x16_t ch = vld1q_u8(p + k);
        uint16x8_t w0 = vmovl_u8(vget_low_u8(ch));
        uint16x8_t w1 = vmovl_u8(vget_high_u8(ch));
        uint32x4x4_t s;
        s.val[1] = vfg;
        s.val[2] = vbg;
        s.val[3] = vae;
        s.val[0] = vmovl_u16(vget_low_u16(w0));
        vst4q_u32((uint32_t *)(dest + k), s);
        s.val[0] = vmovl_u16(vget_high_u16(w0));
        vst4q_u32((uint32_t *)(dest + k + 4), s);
        s.val[0] = vmovl_u16(vget_low_u16(w1));
        vst4q_u32((uint32_t *)(dest + k + 8), s);
        s.val[0] = vmovl_u16(vget_high_u16(w1));
        vst4q_u32((uint32_t *)(dest + k + 12), s);
        k += 16;
    }
    if (k + 8 <= n) {
        uint8x8_t ch = vld1_u8(p + k);
        uint16x8_t w = vmovl_u8(ch);
        uint32x4x4_t s;
        s.val[1] = vfg;
        s.val[2] = vbg;
        s.val[3] = vae;
        s.val[0] = vmovl_u16(vget_low_u16(w));
        vst4q_u32((uint32_t *)(dest + k), s);
        s.val[0] = vmovl_u16(vget_high_u16(w));
        vst4q_u32((uint32_t *)(dest + k + 4), s);
        k += 8;
    }
    if (k + 4 <= n) {
        uint32_t packed = (uint32_t)p[k]
            | ((uint32_t)p[k + 1] << 8)
            | ((uint32_t)p[k + 2] << 16)
            | ((uint32_t)p[k + 3] << 24);
        uint32x4x4_t s;
        s.val[0] = vmovl_u16(vget_low_u16(vmovl_u8(vreinterpret_u8_u32(vdup_n_u32(packed)))));
        s.val[1] = vfg;
        s.val[2] = vbg;
        s.val[3] = vae;
        vst4q_u32((uint32_t *)(dest + k), s);
        k += 4;
    }
    for (; k < n; k++) {
        dest[k].content = content_scalar(p[k], WIDE_NARROW);
        dest[k].fg = fg;
        dest[k].bg = bg;
        dest[k].attrs = attrs;
        dest[k].extra = extra;
    }
#else
    for (size_t k = 0; k < n; k++) {
        dest[k].content = content_scalar(p[k], WIDE_NARROW);
        dest[k].fg = fg;
        dest[k].bg = bg;
        dest[k].attrs = attrs;
        dest[k].extra = extra;
    }
#endif
    if (extra) {
        for (size_t i = 0; i < n; i++) jt_rare_retain(s, extra);
        s->pool_cells += (int32_t)n;
    }
}

static int cell_pooled(const Cell *c) {
    return c->extra || ((c->content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME);
}

static void cell_retain(jt_scr *s, const Cell *c) {
    if (!s || !c || !cell_pooled(c)) return;
    if ((c->content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME)
        jt_grapheme_retain(s, c->content & CONTENT_PAYLOAD);
    if (c->extra) jt_rare_retain(s, c->extra);
    s->pool_cells++;
}

static void cell_release(jt_scr *s, Cell *c) {
    if (!s || !c || !cell_pooled(c)) return;
    if ((c->content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME)
        jt_grapheme_release(s, c->content & CONTENT_PAYLOAD);
    if (c->extra) jt_rare_release(s, c->extra);
    if (s->pool_cells > 0) s->pool_cells--;
}

static void release_cells(jt_scr *s, Cell *row, int32_t n) {
    if (!s->pool_cells) return;
    for (int32_t i = 0; i < n; i++) cell_release(s, &row[i]);
}

static void stamp_cell(jt_scr *s, Cell *dst, Cell neu) {
    if (!cell_pooled(dst) && !cell_pooled(&neu)) {
        *dst = neu;
        return;
    }
    cell_release(s, dst);
    *dst = neu;
    cell_retain(s, dst);
}

static int row_erased(const jt_scr *s, int32_t y) {
    const jt_buf *b = s->active;
    int32_t py = phys_y(b, y);
    return b->erased && py >= 0 && py < b->grid_rows && b->erased[py];
}

static void set_erased(jt_scr *s, int32_t y, Cell proto) {
    jt_buf *b = s->active;
    if (s->pool_cells && !row_erased(s, y))
        release_cells(s, row_at(s, y), s->cols);
    int32_t py = phys_y(b, y);
    b->erased[py] = 1;
    if (b->erase) b->erase[py] = proto;
}

static void materialize_row(jt_scr *s, int32_t y) {
    uint8_t *e = erased_at(s, y);
    if (!*e) return;
    jt_buf *b = s->active;
    Cell proto = erased_blank(b, phys_y(b, y), blank_cell(s));
    fill_cells(row_at(s, y), s->cols, proto);
    *e = 0;
}

static void mark_row(jt_scr *s, int32_t y) {
    if (y < 0 || y >= s->rows) return;
    *dirty_at(s, y) = 1;
}

static void mark_all(jt_scr *s) {
    for (int32_t y = 0; y < s->rows; y++) mark_row(s, y);
}

static void fill_row(jt_scr *s, int32_t y) {
    set_erased(s, y, blank_cell(s));
    *wrap_at(s, y) = 0;
    mark_row(s, y);
}

static void clamp_cursor(jt_buf *b, int32_t cols, int32_t rows) {
    if (b->cx < 0) b->cx = 0;
    if (b->cy < 0) b->cy = 0;
    if (b->cx >= cols) b->cx = cols - 1;
    if (b->cy >= rows) b->cy = rows - 1;
}

static void rowmap_identity(int32_t *map, int32_t rows) {
    for (int32_t i = 0; i < rows; i++) map[i] = i;
}

static int buf_init(jt_buf *b, int32_t cols, int32_t vis_rows, int32_t extra, Cell blank) {
    memset(b, 0, sizeof *b);
    int32_t grid_rows = vis_rows + extra;
    if (grid_rows < vis_rows) grid_rows = vis_rows;
    b->grid_rows = grid_rows;
    b->grid = grid_alloc(cols, grid_rows);
    b->rowmap = (int32_t *)malloc((size_t)vis_rows * sizeof(int32_t));
    b->tabstops = (uint8_t *)malloc((size_t)cols);
    b->dirty = (uint8_t *)calloc((size_t)grid_rows, 1);
    b->wrap = (uint8_t *)calloc((size_t)grid_rows, 1);
    b->erased = (uint8_t *)calloc((size_t)grid_rows, 1);
    b->erase = (Cell *)calloc((size_t)grid_rows, sizeof(Cell));
    if (!b->grid || !b->rowmap || !b->tabstops || !b->dirty || !b->wrap || !b->erased || !b->erase) {
        free(b->grid);
        free(b->rowmap);
        free(b->tabstops);
        free(b->dirty);
        free(b->wrap);
        free(b->erased);
        free(b->erase);
        memset(b, 0, sizeof *b);
        return 0;
    }
    fill_cells(b->grid, cols * vis_rows, blank);
    if (extra > 0) memset(b->erased + vis_rows, 1, (size_t)extra);
    rowmap_identity(b->rowmap, vis_rows);
    default_tabs(b->tabstops, cols);
    memset(b->dirty, 1, (size_t)vis_rows);
    b->scroll_bottom = vis_rows - 1;
    return 1;
}

static void buf_free(jt_buf *b) {
    free(b->grid);
    free(b->rowmap);
    free(b->tabstops);
    free(b->dirty);
    free(b->wrap);
    free(b->erased);
    free(b->erase);
    memset(b, 0, sizeof *b);
}

static void sb_alloc(jt_scr *s, int32_t cap, int32_t cols, int32_t extra_base) {
    free(s->sb_idx);
    free(s->sb_free);
    free(s->sb_wrap);
    s->sb_idx = NULL;
    s->sb_free = NULL;
    s->sb_wrap = NULL;
    s->sb_head = 0;
    s->sb_len = 0;
    s->sb_free_n = 0;
    s->sb_stride = cols;
    if (cap <= 0) {
        s->scrollback_cap = 0;
        return;
    }
    s->sb_idx = (int32_t *)malloc((size_t)cap * sizeof(int32_t));
    s->sb_free = (int32_t *)malloc((size_t)cap * sizeof(int32_t));
    s->sb_wrap = (uint8_t *)calloc((size_t)cap, 1);
    if (!s->sb_idx || !s->sb_free || !s->sb_wrap) {
        free(s->sb_idx);
        free(s->sb_free);
        free(s->sb_wrap);
        s->sb_idx = NULL;
        s->sb_free = NULL;
        s->sb_wrap = NULL;
        s->scrollback_cap = 0;
        return;
    }
    for (int32_t i = 0; i < cap; i++) s->sb_free[i] = extra_base + i;
    s->sb_free_n = cap;
    s->scrollback_cap = cap;
}

static int32_t sb_push_falling(jt_scr *s) {
    s->lines_scrolled++;
    if (s->scrollback_cap <= 0 || !s->sb_idx) return -1;
    s->damage_gen++;
    jt_buf *b = &s->primary;
    int32_t falling = b->rowmap[0];
    uint8_t wrap = (b->wrap && falling >= 0 && falling < b->grid_rows) ? b->wrap[falling] : 0;
    int32_t incoming;
    if (s->sb_len < s->scrollback_cap && s->sb_free_n > 0) {
        incoming = s->sb_free[--s->sb_free_n];
    } else {
        incoming = s->sb_idx[s->sb_head];
    }
    s->sb_idx[s->sb_head] = falling;
    if (s->sb_wrap) s->sb_wrap[s->sb_head] = wrap;
    s->sb_head++;
    if (s->sb_head >= s->scrollback_cap) s->sb_head = 0;
    if (s->sb_len < s->scrollback_cap) s->sb_len++;
    return incoming;
}

static int32_t sb_phys(const jt_scr *s, int32_t i) {
    int32_t phys = s->sb_head - s->sb_len + i;
    if (phys < 0) phys += s->scrollback_cap;
    return phys;
}

static int ensure_alt(jt_scr *s) {
    if (s->alt.grid) return 1;
    return buf_init(&s->alt, s->cols, s->rows, 0, blank_cell(s));
}

static void fix_wide_row(jt_scr *s, Cell *row, int32_t cols, Cell blank) {
    int32_t x = 0;
    while (x < cols) {
        uint32_t w = row[x].content & CONTENT_WIDE_MASK;
        if (w == WIDE_FULL) {
            if (x + 1 < cols && (row[x + 1].content & CONTENT_WIDE_MASK) == WIDE_TAIL) {
                x += 2;
                continue;
            }
            stamp_cell(s, &row[x], blank);
            if (x + 1 < cols) stamp_cell(s, &row[x + 1], blank);
            x += 2;
            continue;
        }
        if (w == WIDE_TAIL) {
            stamp_cell(s, &row[x], blank);
            x++;
            continue;
        }
        x++;
    }
}

static void rotate_up(jt_scr *s, jt_buf *b, int32_t top, int32_t bot) {
    s->damage_gen++;
    int32_t span = bot - top;
    int32_t first = b->rowmap[top];
    if (span > 0) {
        memmove(&b->rowmap[top], &b->rowmap[top + 1], (size_t)span * sizeof(int32_t));
    }
    b->rowmap[bot] = first;
}

static void rotate_down(jt_scr *s, jt_buf *b, int32_t top, int32_t bot) {
    s->damage_gen++;
    int32_t span = bot - top;
    int32_t last = b->rowmap[bot];
    if (span > 0) {
        memmove(&b->rowmap[top + 1], &b->rowmap[top], (size_t)span * sizeof(int32_t));
    }
    b->rowmap[top] = last;
}

static void scroll_up(jt_scr *s) {
    jt_buf *b = s->active;
    int32_t top = b->scroll_top, bot = b->scroll_bottom;
    if (top == 0 && !s->in_alt) {
        int32_t incoming = sb_push_falling(s);
        if (incoming >= 0) {
            if (bot > top) {
                memmove(&b->rowmap[top], &b->rowmap[top + 1],
                        (size_t)(bot - top) * sizeof(int32_t));
            }
            b->rowmap[bot] = incoming;
            fill_row(s, bot);
            return;
        }
    }
    if (bot > top) rotate_up(s, b, top, bot);
    fill_row(s, bot);
}

static void scroll_down(jt_scr *s) {
    jt_buf *b = s->active;
    int32_t top = b->scroll_top, bot = b->scroll_bottom;
    if (bot > top) rotate_down(s, b, top, bot);
    fill_row(s, top);
}

void jt_scr_index(jt_scr *s) {
    jt_buf *b = s->active;
    b->pending_wrap = 0;
    if (b->cy == b->scroll_bottom) {
        scroll_up(s);
        return;
    }
    if (b->cy < s->rows - 1) b->cy++;
}

void jt_scr_ri(jt_scr *s) {
    jt_buf *b = s->active;
    b->pending_wrap = 0;
    if (b->cy == b->scroll_top) {
        scroll_down(s);
        return;
    }
    if (b->cy > 0) b->cy--;
}

void jt_scr_cr(jt_scr *s) {
    s->active->pending_wrap = 0;
    s->active->cx = 0;
}

void jt_scr_nel(jt_scr *s) {
    jt_scr_cr(s);
    jt_scr_index(s);
}

void jt_scr_cub(jt_scr *s, int n) {
    jt_buf *b = s->active;
    if (n < 1) n = 1;
    int wrap_ext = s->reverse_wrap_ext && s->auto_wrap;
    int wrap_rev = !wrap_ext && s->reverse_wrap && s->auto_wrap;
    if (!wrap_ext && !wrap_rev) {
        b->pending_wrap = 0;
        b->cx -= n;
        if (b->cx < 0) b->cx = 0;
        return;
    }
    if (b->pending_wrap) {
        n -= 1;
        b->pending_wrap = 0;
        if (n == 0) return;
    }
    int32_t top = b->scroll_top;
    int32_t bot = b->scroll_bottom;
    int32_t right = s->cols > 0 ? s->cols - 1 : 0;
    int32_t left = 0;
    if (b->cx == left && wrap_rev && b->cy <= top) {
        b->cx = left;
        b->cy = top;
        return;
    }
    while (n > 0) {
        int32_t max = b->cx - left;
        int32_t amount = max < n ? max : n;
        n -= (int)amount;
        b->cx -= amount;
        if (n == 0) break;
        if (b->cy == top) {
            if (!wrap_ext) break;
            b->cx = right;
            b->cy = bot;
            n -= 1;
            continue;
        }
        if (b->cy == 0) break;
        if (!wrap_ext && !*wrap_at(s, b->cy - 1)) break;
        b->cx = right;
        b->cy -= 1;
        n -= 1;
    }
}

void jt_scr_bs(jt_scr *s) {
    jt_scr_cub(s, 1);
}

void jt_scr_tab(jt_scr *s) {
    jt_buf *b = s->active;
    b->pending_wrap = 0;
    int32_t x = b->cx + 1;
    while (x < s->cols && !b->tabstops[x]) x++;
    b->cx = x < s->cols ? x : s->cols - 1;
}

void jt_scr_cup(jt_scr *s, int row, int col) {
    jt_buf *b = s->active;
    b->pending_wrap = 0;
    int y0 = 0, y1 = s->rows - 1;
    if (s->origin_mode) {
        y0 = b->scroll_top;
        y1 = b->scroll_bottom;
    }
    int y = y0 + row;
    if (y < y0) y = y0;
    if (y > y1) y = y1;
    b->cy = y;
    if (col < 0) col = 0;
    if (col > s->cols - 1) col = s->cols - 1;
    b->cx = col;
}

static void consume_wrap(jt_scr *s) {
    jt_buf *b = s->active;
    if (!(b->pending_wrap && s->auto_wrap)) return;
    int32_t y = b->cy;
    *wrap_at(s, y) = 1;
    mark_row(s, y);
    b->pending_wrap = 0;
    b->cx = 0;
    jt_scr_index(s);
}

static void place_graphic(jt_scr *s, uint32_t content) {
    jt_buf *b = s->active;
    materialize_row(s, b->cy);
    Cell neu;
    neu.content = content;
    neu.fg = s->pen.fg;
    neu.bg = s->pen.bg;
    neu.attrs = s->pen.attrs;
    neu.extra = s->pen.extra;
    stamp_cell(s, row_at(s, b->cy) + b->cx, neu);
    mark_row(s, b->cy);
    if (b->cx + 1 >= s->cols) {
        b->cx = s->cols - 1;
        b->pending_wrap = s->auto_wrap;
    } else {
        b->cx++;
    }
}

static void attach_mark(jt_scr *s, uint32_t mark) {
    jt_buf *b = s->active;
    int32_t y = b->cy;
    int32_t x;
    if (b->pending_wrap) x = s->cols - 1;
    else if (b->cx > 0) x = b->cx - 1;
    else return;
    materialize_row(s, y);
    Cell *row = row_at(s, y);
    if ((row[x].content & CONTENT_WIDE_MASK) == WIDE_TAIL && x > 0) x--;
    if ((row[x].content & CONTENT_WIDE_MASK) == WIDE_HEAD) return;
    uint32_t wide = row[x].content & CONTENT_WIDE_MASK;
    if ((row[x].content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME) {
        uint32_t gid = row[x].content & CONTENT_PAYLOAD;
        if (jt_grapheme_append_exclusive(s, gid, mark)) {
            mark_row(s, y);
            return;
        }
    }
    uint32_t cps[16];
    uint16_t n = 0;
    if ((row[x].content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME) {
        uint16_t gn = 0;
        const uint32_t *old = jt_grapheme_get(s, row[x].content & CONTENT_PAYLOAD, &gn);
        if (!old || gn == 0 || gn >= 16) return;
        memcpy(cps, old, (size_t)gn * sizeof(uint32_t));
        n = gn;
    } else {
        cps[0] = row[x].content & CONTENT_PAYLOAD;
        n = 1;
    }
    cps[n++] = mark;
    uint32_t id = jt_grapheme_intern(s, cps, n);
    if (!id) return;
    Cell neu = row[x];
    neu.content = content_grapheme(id, wide);
    stamp_cell(s, &row[x], neu);
    mark_row(s, y);
}

void jt_scr_set_mode_2027(jt_scr *s, int on) {
    if (s) s->mode_2027 = on ? 1 : 0;
}

int jt_scr_mode_2027(const jt_scr *s) {
    return s && s->mode_2027;
}

static int attach_col(jt_scr *s, int32_t *x_out) {
    jt_buf *b = s->active;
    int32_t x;
    if (b->pending_wrap) x = s->cols - 1;
    else if (b->cx > 0) x = b->cx - 1;
    else return 0;
    materialize_row(s, b->cy);
    Cell *row = row_at(s, b->cy);
    if ((row[x].content & CONTENT_WIDE_MASK) == WIDE_TAIL && x > 0) x--;
    if ((row[x].content & CONTENT_WIDE_MASK) == WIDE_HEAD) return 0;
    *x_out = x;
    return 1;
}

static int load_cluster(jt_scr *s, Cell *cell, uint32_t *cps, uint16_t *n_out) {
    if ((cell->content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME) {
        uint16_t gn = 0;
        const uint32_t *old = jt_grapheme_get(s, cell->content & CONTENT_PAYLOAD, &gn);
        if (!old || gn == 0) return 0;
        if (gn > 16) gn = 16;
        memcpy(cps, old, (size_t)gn * sizeof(uint32_t));
        *n_out = gn;
        return 1;
    }
    uint32_t p = cell->content & CONTENT_PAYLOAD;
    if (!p) return 0;
    cps[0] = p;
    *n_out = 1;
    return 1;
}

static void shrink_full_to_narrow(jt_scr *s, int32_t x, int32_t y) {
    materialize_row(s, y);
    Cell *row = row_at(s, y);
    if ((row[x].content & CONTENT_WIDE_MASK) != WIDE_FULL) return;
    Cell neu = row[x];
    neu.content = (neu.content & ~CONTENT_WIDE_MASK) | WIDE_NARROW;
    stamp_cell(s, &row[x], neu);
    if (x + 1 < s->cols && (row[x + 1].content & CONTENT_WIDE_MASK) == WIDE_TAIL)
        stamp_cell(s, &row[x + 1], blank_cell(s));
    mark_row(s, y);
}

static void print_wide(jt_scr *s, uint32_t scalar);

static void upgrade_narrow_to_full(jt_scr *s, int32_t x, int32_t y) {
    jt_buf *b = s->active;
    materialize_row(s, y);
    Cell *row = row_at(s, y);
    if ((row[x].content & CONTENT_WIDE_MASK) != WIDE_NARROW) return;

    if (x == s->cols - 1) {
        uint32_t cps[16];
        uint16_t n = 0;
        if (!s->auto_wrap || !load_cluster(s, &row[x], cps, &n) || n == 0) return;
        stamp_cell(s, &row[x], blank_cell(s));
        mark_row(s, y);
        print_wide(s, cps[0]);
        for (uint16_t i = 1; i < n; i++) attach_mark(s, cps[i]);
        return;
    }

    if (s->insert_mode) jt_scr_ich(s, 1);
    materialize_row(s, y);
    row = row_at(s, y);
    if (x + 1 >= s->cols) return;
    Cell full = row[x];
    full.content = (full.content & ~CONTENT_WIDE_MASK) | WIDE_FULL;
    Cell tail = blank_cell(s);
    tail.fg = full.fg;
    tail.bg = full.bg;
    tail.attrs = full.attrs;
    tail.content = content_scalar(0, WIDE_TAIL);
    stamp_cell(s, &row[x], full);
    stamp_cell(s, &row[x + 1], tail);
    mark_row(s, y);
    if (x + 2 >= s->cols) {
        b->cx = s->cols - 1;
        b->pending_wrap = s->auto_wrap;
    } else {
        b->cx = x + 2;
        b->pending_wrap = 0;
    }
}

/* 1 = consumed. 0 = new graphic cluster, use v1 place. */
static int print_2027(jt_scr *s, uint32_t scalar) {
    int32_t x;
    if (!attach_col(s, &x)) return 0;
    Cell *row = row_at(s, s->active->cy);
    uint32_t cps[16];
    uint16_t n = 0;
    if (!load_cluster(s, &row[x], cps, &n) || n == 0) return 0;

    uint32_t prev = cps[0];
    uint8_t state = 0;
    for (uint16_t i = 1; i < n; i++) {
        jt_grapheme_break(prev, cps[i], &state);
        prev = cps[i];
    }
    uint8_t state_before = state;
    if (jt_grapheme_break(prev, scalar, &state)) {
        if (jt_codepoint_width(scalar) == 0) {
            attach_mark(s, scalar);
            return 1;
        }
        return 0;
    }
    int effect = jt_grapheme_width_effect(prev, scalar);
    if (effect == JT_GB_IGNORE) {
        (void)state_before;
        return 1;
    }
    attach_mark(s, scalar);
    if (effect == JT_GB_WIDE) upgrade_narrow_to_full(s, x, s->active->cy);
    else if (effect == JT_GB_NARROW) shrink_full_to_narrow(s, x, s->active->cy);
    return 1;
}

static void print_wide(jt_scr *s, uint32_t scalar) {
    jt_buf *b = s->active;
    consume_wrap(s);
    if (s->insert_mode) jt_scr_ich(s, 2);
    int32_t room = s->cols - b->cx;
    if (room < 2) {
        if (s->auto_wrap) {
            place_graphic(s, content_scalar(0, WIDE_HEAD));
            consume_wrap(s);
        } else {
            place_graphic(s, content_scalar(scalar, WIDE_FULL));
            return;
        }
    }
    materialize_row(s, b->cy);
    Cell *row = row_at(s, b->cy) + b->cx;
    Cell full;
    full.content = content_scalar(scalar, WIDE_FULL);
    full.fg = s->pen.fg;
    full.bg = s->pen.bg;
    full.attrs = s->pen.attrs;
    full.extra = s->pen.extra;
    Cell tail = full;
    tail.content = content_scalar(0, WIDE_TAIL);
    tail.extra = 0;
    stamp_cell(s, row, full);
    if (b->cx + 1 < s->cols) stamp_cell(s, row + 1, tail);
    mark_row(s, b->cy);
    if (b->cx + 2 >= s->cols) {
        b->cx = s->cols - 1;
        b->pending_wrap = s->auto_wrap;
    } else {
        b->cx += 2;
    }
}

void jt_scr_print_wide_run(jt_scr *s, const uint32_t *cps, int n) {
    if (!s || !cps || n <= 0) return;
    if (s->insert_mode || s->mode_2027) {
        for (int i = 0; i < n; i++) jt_scr_print_scalar(s, cps[i]);
        return;
    }
    jt_buf *b = s->active;
    s->last_print = cps[n - 1];
    s->has_last_print = 1;
    uint32_t fg = s->pen.fg, bg = s->pen.bg;
    uint16_t attrs = s->pen.attrs, extra = s->pen.extra;
    Cell tail;
    tail.content = content_scalar(0, WIDE_TAIL);
    tail.fg = fg;
    tail.bg = bg;
    tail.attrs = attrs;
    tail.extra = 0;
    int i = 0;
    while (i < n) {
        if (b->pending_wrap) consume_wrap(s);
        int32_t room = s->cols - b->cx;
        if (room < 2) {
            if (s->auto_wrap) {
                place_graphic(s, content_scalar(0, WIDE_HEAD));
                consume_wrap(s);
            } else {
                place_graphic(s, content_scalar(cps[i], WIDE_FULL));
                i++;
            }
            continue;
        }
        int pairs = room / 2;
        int left = n - i;
        if (pairs > left) pairs = left;
        materialize_row(s, b->cy);
        Cell *dest = row_at(s, b->cy) + b->cx;
        for (int k = 0; k < pairs; k++) {
            Cell *d0 = dest + 2 * k;
            Cell full;
            full.content = content_scalar(cps[i + k], WIDE_FULL);
            full.fg = fg;
            full.bg = bg;
            full.attrs = attrs;
            full.extra = extra;
            if (extra == 0 && !cell_pooled(d0) && !cell_pooled(d0 + 1)) {
                d0[0] = full;
                d0[1] = tail;
            } else {
                stamp_cell(s, d0, full);
                stamp_cell(s, d0 + 1, tail);
            }
        }
        mark_row(s, b->cy);
        i += pairs;
        int32_t used = pairs * 2;
        if (b->cx + used >= s->cols) {
            b->cx = s->cols - 1;
            b->pending_wrap = s->auto_wrap;
        } else {
            b->cx += used;
            b->pending_wrap = 0;
        }
    }
}

void jt_scr_print_narrow_run(jt_scr *s, const uint32_t *cps, int n) {
    if (!s || !cps || n <= 0) return;
    if (s->insert_mode || s->mode_2027) {
        for (int i = 0; i < n; i++) jt_scr_print_scalar(s, cps[i]);
        return;
    }
    jt_buf *b = s->active;
    s->last_print = cps[n - 1];
    s->has_last_print = 1;
    int off = 0;
    int32_t marked_y = -1;
    while (off < n) {
        consume_wrap(s);
        int32_t room = s->cols - b->cx;
        if (room <= 0) {
            b->cx = s->cols > 0 ? s->cols - 1 : 0;
            room = 1;
        }
        int take = (n - off) < room ? (n - off) : room;
        if (row_erased(s, b->cy) && b->cx == 0 && take == s->cols)
            *erased_at(s, b->cy) = 0;
        else
            materialize_row(s, b->cy);
        Cell *dest = row_at(s, b->cy) + b->cx;
        for (int k = 0; k < take; k++) {
            Cell neu;
            neu.content = content_scalar(cps[off + k], WIDE_NARROW);
            neu.fg = s->pen.fg;
            neu.bg = s->pen.bg;
            neu.attrs = s->pen.attrs;
            neu.extra = s->pen.extra;
            if (!cell_pooled(dest + k) && !cell_pooled(&neu)) dest[k] = neu;
            else stamp_cell(s, dest + k, neu);
        }
        if (marked_y != b->cy) {
            mark_row(s, b->cy);
            marked_y = b->cy;
        }
        off += take;
        if (b->cx + take >= s->cols) {
            b->cx = s->cols - 1;
            b->pending_wrap = s->auto_wrap;
        } else {
            b->cx += take;
            b->pending_wrap = 0;
        }
    }
}

void jt_scr_print_cluster(jt_scr *s, uint32_t base, const uint32_t *marks, int nmarks) {
    if (!s) return;
    if (nmarks <= 0) {
        jt_scr_print_scalar(s, base);
        return;
    }
    if (s->insert_mode || s->mode_2027 || jt_codepoint_width(base) != 1) {
        jt_scr_print_scalar(s, base);
        for (int i = 0; i < nmarks; i++) jt_scr_print_scalar(s, marks[i]);
        return;
    }
    uint32_t cps[16];
    uint16_t n = 0;
    cps[n++] = base;
    for (int i = 0; i < nmarks && n < 16; i++) cps[n++] = marks[i];
    uint32_t id = jt_grapheme_intern(s, cps, n);
    if (!id) {
        jt_scr_print_scalar(s, base);
        for (int i = 0; i < nmarks; i++) jt_scr_print_scalar(s, marks[i]);
        return;
    }
    s->last_print = base;
    s->has_last_print = 1;
    consume_wrap(s);
    place_graphic(s, content_grapheme(id, WIDE_NARROW));
}

void jt_scr_print_scalar(jt_scr *s, uint32_t scalar) {
    if (scalar >= 0x20 && scalar < 0x7F) {
        s->last_print = scalar;
        s->has_last_print = 1;
        consume_wrap(s);
        if (s->insert_mode) jt_scr_ich(s, 1);
        place_graphic(s, content_scalar(scalar, WIDE_NARROW));
        return;
    }
    if (s->mode_2027 && print_2027(s, scalar)) return;
    int w = jt_codepoint_width(scalar);
    if (w == 0) {
        attach_mark(s, scalar);
        return;
    }
    s->last_print = scalar;
    s->has_last_print = 1;
    if (w >= 2) {
        print_wide(s, scalar);
        return;
    }
    consume_wrap(s);
    if (s->insert_mode) jt_scr_ich(s, 1);
    place_graphic(s, content_scalar(scalar, WIDE_NARROW));
}

void jt_scr_print_run(jt_scr *s, const uint8_t *p, size_t n) {
    if (s->insert_mode) {
        for (size_t i = 0; i < n; i++) jt_scr_print_scalar(s, p[i]);
        return;
    }
    size_t i = 0;
    jt_buf *b = s->active;
    while (i < n) {
        consume_wrap(s);
        int32_t room = s->cols - b->cx;
        if (room <= 0) {
            b->cx = s->cols > 0 ? s->cols - 1 : 0;
            room = 1;
        }
        size_t take = (size_t)room < (n - i) ? (size_t)room : (n - i);
        if (row_erased(s, b->cy) && b->cx == 0 && (int32_t)take == s->cols) {
            *erased_at(s, b->cy) = 0;
        } else {
            materialize_row(s, b->cy);
        }
        Cell *dest = row_at(s, b->cy) + b->cx;
        store_ascii_cells(s, dest, p + i, take, s->pen.fg, s->pen.bg, s->pen.attrs, s->pen.extra);
        mark_row(s, b->cy);
        i += take;
        if (b->cx + (int32_t)take >= s->cols) {
            b->cx = s->cols - 1;
            b->pending_wrap = s->auto_wrap;
        } else {
            b->cx += (int32_t)take;
        }
    }
    if (n > 0) {
        s->last_print = p[n - 1];
        s->has_last_print = 1;
    }
}

void jt_scr_ich(jt_scr *s, int n) {
    jt_buf *b = s->active;
    if (n <= 0 || b->cx >= s->cols) return;
    materialize_row(s, b->cy);
    Cell *row = row_at(s, b->cy);
    int32_t count = n < (s->cols - b->cx) ? n : (s->cols - b->cx);
    release_cells(s, row + (s->cols - count), count);
    for (int32_t i = s->cols - 1; i >= b->cx + count; i--) {
        row[i] = row[i - count];
    }
    Cell blank = blank_cell(s);
    for (int32_t i = 0; i < count; i++) row[b->cx + i] = blank;
    fix_wide_row(s, row, s->cols, blank);
    *wrap_at(s, b->cy) = 0;
    mark_row(s, b->cy);
}

void jt_scr_dch(jt_scr *s, int n) {
    jt_buf *b = s->active;
    if (n <= 0 || b->cx >= s->cols) return;
    materialize_row(s, b->cy);
    Cell *row = row_at(s, b->cy);
    int count = n < (s->cols - b->cx) ? n : (s->cols - b->cx);
    release_cells(s, row + b->cx, count);
    for (int i = b->cx; i < s->cols - count; i++) {
        row[i] = row[i + count];
    }
    Cell blank = blank_cell(s);
    for (int i = s->cols - count; i < s->cols; i++) row[i] = blank;
    fix_wide_row(s, row, s->cols, blank);
    *wrap_at(s, b->cy) = 0;
    mark_row(s, b->cy);
}

void jt_scr_ech(jt_scr *s, int n) {
    jt_buf *b = s->active;
    Cell blank = blank_cell(s);
    int count = n < (s->cols - b->cx) ? n : (s->cols - b->cx);
    if (count < 0) count = 0;
    materialize_row(s, b->cy);
    Cell *row = row_at(s, b->cy) + b->cx;
    for (int i = 0; i < count; i++) stamp_cell(s, &row[i], blank);
    fix_wide_row(s, row_at(s, b->cy), s->cols, blank);
    mark_row(s, b->cy);
}

void jt_scr_il(jt_scr *s, int n) {
    jt_buf *b = s->active;
    if (b->cy < b->scroll_top || b->cy > b->scroll_bottom) return;
    int nn = n < 1 ? 1 : n;
    int32_t top = b->cy, bot = b->scroll_bottom;
    for (int k = 0; k < nn; k++) {
        if (bot > top) rotate_down(s, b, top, bot);
        fill_row(s, top);
    }
}

void jt_scr_dl(jt_scr *s, int n) {
    jt_buf *b = s->active;
    if (b->cy < b->scroll_top || b->cy > b->scroll_bottom) return;
    int nn = n < 1 ? 1 : n;
    int32_t top = b->cy, bot = b->scroll_bottom;
    for (int k = 0; k < nn; k++) {
        if (bot > top) rotate_up(s, b, top, bot);
        fill_row(s, bot);
    }
}

static void fill_rect(jt_scr *s, int x1, int y1, int x2, int y2, int clear_wrap) {
    Cell blank = blank_cell(s);
    for (int y = y1; y <= y2; y++) {
        int xa = (y == y1) ? x1 : 0;
        int xb = (y == y2) ? x2 : s->cols - 1;
        if (xa == 0 && xb == s->cols - 1) {
            set_erased(s, y, blank);
        } else {
            materialize_row(s, y);
            release_cells(s, row_at(s, y) + xa, xb - xa + 1);
            fill_cells(row_at(s, y) + xa, xb - xa + 1, blank);
        }
        if (clear_wrap && xa == 0 && xb == s->cols - 1) *wrap_at(s, y) = 0;
        mark_row(s, y);
    }
}

void jt_scr_el(jt_scr *s, int mode) {
    jt_buf *b = s->active;
    switch (mode) {
    case 1:
        fill_rect(s, 0, b->cy, b->cx, b->cy, 0);
        break;
    case 2:
        fill_row(s, b->cy);
        break;
    default:
        fill_rect(s, b->cx, b->cy, s->cols - 1, b->cy, 1);
        *wrap_at(s, b->cy) = 0;
        break;
    }
}

void jt_scr_ed(jt_scr *s, int mode) {
    jt_buf *b = s->active;
    switch (mode) {
    case 1:
        for (int y = 0; y <= b->cy; y++) {
            int x2 = (y == b->cy) ? b->cx : s->cols - 1;
            fill_rect(s, 0, y, x2, y, y != b->cy);
            if (y != b->cy) *wrap_at(s, y) = 0;
        }
        break;
    case 2:
        for (int y = 0; y < s->rows; y++) fill_row(s, y);
        break;
    case 3:
        jt_scr_clear_history(s);
        break;
    default:
        fill_rect(s, b->cx, b->cy, s->cols - 1, b->cy, 1);
        *wrap_at(s, b->cy) = 0;
        for (int y = b->cy + 1; y < s->rows; y++) fill_row(s, y);
        break;
    }
}

void jt_scr_decstbm(jt_scr *s, int top, int bot) {
    jt_buf *b = s->active;
    if (top < 0) top = 0;
    if (bot >= s->rows) bot = s->rows - 1;
    if (bot > top) {
        b->scroll_top = top;
        b->scroll_bottom = bot;
    } else {
        b->scroll_top = 0;
        b->scroll_bottom = s->rows - 1;
    }
    jt_scr_cup(s, 0, 0);
}

void jt_scr_cursor_copy(jt_buf *dst, const jt_buf *src) {
    if (!dst || !src) return;
    dst->cx = src->cx;
    dst->cy = src->cy;
    dst->pending_wrap = src->pending_wrap;
}

void jt_scr_decsc(jt_scr *s) {
    jt_buf *b = s->active;
    s->saved.x = b->cx;
    s->saved.y = b->cy;
    s->saved.pending_wrap = b->pending_wrap;
    s->saved.fg = s->pen.fg;
    s->saved.bg = s->pen.bg;
    s->saved.ul_color = s->pen.ul_color;
    s->saved.attrs = s->pen.attrs;
    s->saved.extra = s->pen.extra;
    s->saved.g0 = s->g0;
    s->saved.g1 = s->g1;
    s->saved.gl = s->gl;
    s->saved.valid = 1;
}

void jt_scr_decaln(jt_scr *s) {
    jt_buf *b = s->active;
    b->scroll_top = 0;
    b->scroll_bottom = s->rows - 1;
    s->origin_mode = 0;
    s->pen.attrs = 0;
    jt_pen_refresh_extra(s);
    for (int32_t y = 0; y < s->rows; y++) {
        materialize_row(s, y);
        Cell *row = row_at(s, y);
        for (int32_t x = 0; x < s->cols; x++) {
            Cell neu;
            neu.content = content_scalar('E', WIDE_NARROW);
            neu.fg = s->pen.fg;
            neu.bg = s->pen.bg;
            neu.attrs = 0;
            neu.extra = 0;
            stamp_cell(s, row + x, neu);
        }
        *wrap_at(s, y) = 0;
        mark_row(s, y);
    }
    jt_scr_cup(s, 0, 0);
}

void jt_scr_decrc(jt_scr *s) {
    if (!s->saved.valid) return;
    jt_buf *b = s->active;
    b->cx = s->saved.x;
    b->cy = s->saved.y;
    b->pending_wrap = s->saved.pending_wrap;
    s->pen.fg = s->saved.fg;
    s->pen.bg = s->saved.bg;
    s->pen.ul_color = s->saved.ul_color;
    s->pen.attrs = s->saved.attrs;
    s->pen.extra = s->saved.extra;
    s->g0 = s->saved.g0;
    s->g1 = s->saved.g1;
    s->gl = s->saved.gl;
    clamp_cursor(b, s->cols, s->rows);
}

void jt_scr_switch_screen_mode(jt_scr *s, int mode, int enabled) {
    if (mode != 47 && mode != 1047 && mode != 1049) return;
    if (!ensure_alt(s)) return;

    if (mode == 1049 && enabled) jt_scr_decsc(s);

    if (mode == 1047 && !enabled && s->in_alt) {
        jt_scr_ed(s, 2);
    }

    jt_buf *old = s->active;
    jt_buf *dst = enabled ? &s->alt : &s->primary;
    int changed = old != dst;
    s->active = dst;
    s->in_alt = enabled ? 1 : 0;
    clamp_cursor(s->active, s->cols, s->rows);
    mark_all(s);

    if (mode == 47 || mode == 1047) {
        if (changed) {
            jt_scr_cursor_copy(s->active, old);
            clamp_cursor(s->active, s->cols, s->rows);
        }
        return;
    }

    /* 1049 */
    if (enabled) {
        jt_scr_ed(s, 2);
        if (changed) {
            jt_scr_cursor_copy(s->active, old);
            clamp_cursor(s->active, s->cols, s->rows);
        }
    } else {
        jt_scr_decrc(s);
    }
}

void jt_scr_clear_history(jt_scr *s) {
    if (s->sb_idx && s->sb_free) {
        for (int32_t i = 0; i < s->sb_len; i++) {
            int32_t phys = sb_phys(s, i);
            int32_t idx = s->sb_idx[phys];
            if (idx >= 0 && s->sb_free_n < s->scrollback_cap)
                s->sb_free[s->sb_free_n++] = idx;
        }
    }
    s->sb_head = 0;
    s->sb_len = 0;
    s->lines_scrolled = 0;
}

int32_t jt_scr_sb_len(const jt_scr *s) { return s->sb_len; }

Cell *jt_scr_row(jt_scr *s, int32_t y) {
    if (!s || !s->active || !s->active->grid || y < 0 || y >= s->rows) return NULL;
    materialize_row(s, y);
    return row_at(s, y);
}

void jt_scr_copy_row(const jt_scr *s, int32_t y, Cell *dst, int32_t dst_cols, Cell blank) {
    if (!dst || dst_cols <= 0) return;
    if (!s || !s->active || !s->active->grid || y < 0 || y >= s->rows) {
        for (int32_t x = 0; x < dst_cols; x++) dst[x] = blank;
        return;
    }
    int32_t n = s->cols < dst_cols ? s->cols : dst_cols;
    if (row_erased(s, y)) {
        const jt_buf *b = s->active;
        fill_cells(dst, n, erased_blank(b, phys_y(b, y), blank));
    } else {
        memcpy(dst, row_at_c(s, y), (size_t)n * sizeof(Cell));
    }
    for (int32_t x = n; x < dst_cols; x++) dst[x] = blank;
}

int jt_scr_sb_wrapped(const jt_scr *s, int32_t i) {
    if (!s || !s->sb_wrap || i < 0 || i >= s->sb_len) return 0;
    return s->sb_wrap[sb_phys(s, i)] != 0;
}

void jt_sync_drop_snap(jt_scr *s) {
    if (!s) return;
    __atomic_store_n(&s->sync_snap_valid, 0, __ATOMIC_RELEASE);
    if (s->sync_pin) {
        s->sync_pin = 0;
        jt_pools_reclaim(s);
    }
}

void jt_sync_presented(jt_scr *s) {
    jt_sync_drop_snap(s);
}

static void sync_snap_free(jt_scr *s) {
    jt_sync_drop_snap(s);
    free(s->sync_snap);
    s->sync_snap = NULL;
    s->sync_snap_cols = 0;
    s->sync_snap_rows = 0;
    s->sync_snap_cx = 0;
    s->sync_snap_cy = 0;
}

void jt_sync_capture(jt_scr *s) {
    if (!s || s->cols <= 0 || s->rows <= 0) return;
    int32_t cols = s->cols, rows = s->rows;
    if (!s->sync_snap || s->sync_snap_cols != cols || s->sync_snap_rows != rows) {
        sync_snap_free(s);
        s->sync_snap = (Cell *)malloc((size_t)cols * (size_t)rows * sizeof(Cell));
        if (!s->sync_snap) return;
        s->sync_snap_cols = cols;
        s->sync_snap_rows = rows;
    }
    Cell blank = blank_cell(s);
    for (int32_t y = 0; y < rows; y++)
        jt_scr_copy_row(s, y, s->sync_snap + (size_t)y * (size_t)cols, cols, blank);
    if (s->pool_cells) s->sync_pin = 1;
    s->sync_snap_cx = s->active ? s->active->cx : 0;
    s->sync_snap_cy = s->active ? s->active->cy : 0;
    __atomic_store_n(&s->sync_snap_valid, 1, __ATOMIC_RELEASE);
}

int jt_sync_snap_valid(const jt_scr *s) {
    return s && s->sync_snap && __atomic_load_n(&s->sync_snap_valid, __ATOMIC_ACQUIRE);
}

void jt_sync_snap_cursor(const jt_scr *s, int32_t *cx, int32_t *cy) {
    int32_t x = 0, y = 0;
    if (jt_sync_snap_valid(s)) {
        x = s->sync_snap_cx;
        y = s->sync_snap_cy;
    }
    if (cx) *cx = x;
    if (cy) *cy = y;
}

void jt_scr_copy_sync_row(const jt_scr *s, int32_t y, Cell *dst, int32_t dst_cols, Cell blank) {
    if (!dst || dst_cols <= 0) return;
    if (!jt_sync_snap_valid(s) || !s->sync_snap || y < 0 || y >= s->sync_snap_rows) {
        for (int32_t x = 0; x < dst_cols; x++) dst[x] = blank;
        return;
    }
    int32_t n = s->sync_snap_cols < dst_cols ? s->sync_snap_cols : dst_cols;
    memcpy(dst, s->sync_snap + (size_t)y * (size_t)s->sync_snap_cols, (size_t)n * sizeof(Cell));
    for (int32_t x = n; x < dst_cols; x++) dst[x] = blank;
}

void jt_scr_copy_sb_row(const jt_scr *s, int32_t i, Cell *dst, int32_t dst_cols, Cell blank) {
    if (!dst || dst_cols <= 0) return;
    if (!s || !s->sb_idx || i < 0 || i >= s->sb_len) {
        for (int32_t x = 0; x < dst_cols; x++) dst[x] = blank;
        return;
    }
    int32_t phys = sb_phys(s, i);
    int32_t idx = s->sb_idx[phys];
    if (!s->primary.grid || idx < 0 || idx >= s->primary.grid_rows) {
        for (int32_t x = 0; x < dst_cols; x++) dst[x] = blank;
        return;
    }
    int32_t n = s->cols < dst_cols ? s->cols : dst_cols;
    if (s->primary.erased && s->primary.erased[idx]) {
        fill_cells(dst, n, erased_blank(&s->primary, idx, blank));
    } else {
        memcpy(dst, s->primary.grid + (size_t)idx * (size_t)s->cols, (size_t)n * sizeof(Cell));
    }
    for (int32_t x = n; x < dst_cols; x++) dst[x] = blank;
}

void jt_scr_mark_dirty(jt_scr *s, int32_t y) { mark_row(s, y); }

void jt_scr_take_dirty(jt_scr *s, uint8_t *dst, int32_t n, uint32_t *damage_gen) {
    if (n < 0) n = 0;
    if (!s || !s->active) {
        if (dst && n > 0) memset(dst, 0, (size_t)n);
        if (damage_gen) *damage_gen = 0;
        return;
    }
    jt_buf *b = s->active;
    int32_t live = s->rows;
    int32_t take = n < live ? n : live;
    if (dst) {
        for (int32_t y = 0; y < take; y++) {
            uint8_t bit = 0;
            if (b->dirty && b->rowmap && y >= 0) {
                int32_t py = b->rowmap[y];
                if (py >= 0 && py < b->grid_rows) bit = b->dirty[py];
            }
            dst[y] = bit;
        }
        if (n > take) memset(dst + take, 0, (size_t)(n - take));
    }
    if (b->dirty && b->grid_rows > 0) memset(b->dirty, 0, (size_t)b->grid_rows);
    if (damage_gen) *damage_gen = s->damage_gen;
}

void jt_scr_wrap_at(jt_scr *s, int32_t y) {
    if (y < 0 || y >= s->rows) return;
    *wrap_at(s, y) = 1;
}

int jt_scr_is_wrapped(const jt_scr *s, int32_t y) {
    if (!s || !s->active || !s->active->wrap || y < 0 || y >= s->rows) return 0;
    const jt_buf *b = s->active;
    return b->wrap[phys_y(b, y)] != 0;
}

static int buf_resize(jt_buf *b, int32_t oc, int32_t orows, int32_t nc, int32_t nr, int32_t extra,
                      Cell blank) {
    int32_t grid_rows = nr + extra;
    if (grid_rows < nr) grid_rows = nr;
    Cell *next = grid_alloc(nc, grid_rows);
    int32_t *rowmap = (int32_t *)malloc((size_t)nr * sizeof(int32_t));
    uint8_t *tabs = (uint8_t *)malloc((size_t)nc);
    uint8_t *dirty = (uint8_t *)calloc((size_t)grid_rows, 1);
    uint8_t *wrap = (uint8_t *)calloc((size_t)grid_rows, 1);
    uint8_t *erased = (uint8_t *)calloc((size_t)grid_rows, 1);
    Cell *erase = (Cell *)calloc((size_t)grid_rows, sizeof(Cell));
    if (!next || !rowmap || !tabs || !dirty || !wrap || !erased || !erase) {
        free(next);
        free(rowmap);
        free(tabs);
        free(dirty);
        free(wrap);
        free(erased);
        free(erase);
        return 0;
    }
    rowmap_identity(rowmap, nr);
    memset(dirty, 1, (size_t)nr);
    default_tabs(tabs, nc);
    int32_t copyC = oc < nc ? oc : nc;
    int32_t copyR = 0;
    if (b->grid && b->rowmap) {
        copyR = orows < nr ? orows : nr;
        for (int32_t y = 0; y < copyR; y++) {
            int32_t py = b->rowmap[y];
            if (py < 0 || py >= b->grid_rows) {
                erased[y] = 1;
                erase[y] = blank;
                continue;
            }
            if (b->erased && b->erased[py]) {
                erased[y] = 1;
                erase[y] = erased_blank(b, py, blank);
            } else {
                memcpy(next + (size_t)y * (size_t)nc, b->grid + (size_t)py * (size_t)oc,
                       (size_t)copyC * sizeof(Cell));
                if (copyC < nc) fill_cells(next + (size_t)y * (size_t)nc + copyC, nc - copyC, blank);
            }
            wrap[y] = b->wrap && py < b->grid_rows ? b->wrap[py] : 0;
        }
    }
    for (int32_t y = copyR; y < nr; y++) {
        erased[y] = 1;
        erase[y] = blank;
    }
    if (extra > 0) memset(erased + nr, 1, (size_t)extra);
    free(b->grid);
    free(b->rowmap);
    free(b->tabstops);
    free(b->dirty);
    free(b->wrap);
    free(b->erased);
    free(b->erase);
    b->grid = next;
    b->rowmap = rowmap;
    b->tabstops = tabs;
    b->dirty = dirty;
    b->wrap = wrap;
    b->erased = erased;
    b->erase = erase;
    b->grid_rows = grid_rows;
    b->scroll_top = 0;
    b->scroll_bottom = nr - 1;
    clamp_cursor(b, nc, nr);
    b->pending_wrap = 0;
    return 1;
}

void jt_scr_resize(jt_scr *s, int32_t nc, int32_t nr) {
    if (nc < 2) nc = 2;
    if (nr < 1) nr = 1;
    if (nc == s->cols && nr == s->rows) return;
    sync_snap_free(s);
    Cell blank = blank_cell(s);
    int32_t oc = s->cols, orows = s->rows;
    int32_t cap = s->scrollback_cap;
    int32_t slen = s->sb_len;

    Cell *hist = NULL;
    uint8_t *hw = NULL;
    if (cap > 0 && slen > 0 && s->primary.grid && s->sb_idx) {
        hist = (Cell *)malloc((size_t)slen * (size_t)oc * sizeof(Cell));
        hw = (uint8_t *)malloc((size_t)slen);
        if (hist && hw) {
            for (int32_t i = 0; i < slen; i++) {
                int32_t phys = sb_phys(s, i);
                Cell *dst = hist + (size_t)i * (size_t)oc;
                jt_scr_copy_sb_row(s, i, dst, oc, blank);
                hw[i] = s->sb_wrap ? s->sb_wrap[phys] : 0;
                if (s->pool_cells) {
                    for (int32_t x = 0; x < oc; x++) cell_retain(s, &dst[x]);
                }
            }
        } else {
            free(hist);
            free(hw);
            hist = NULL;
            hw = NULL;
            slen = 0;
        }
    }

    if (s->pool_cells && s->primary.grid && s->sb_idx && s->sb_free) {
        for (int32_t i = 0; i < slen; i++) {
            int32_t idx = s->sb_idx[sb_phys(s, i)];
            if (idx < 0 || idx >= s->primary.grid_rows) continue;
            if (s->primary.erased && s->primary.erased[idx]) continue;
            release_cells(s, s->primary.grid + (size_t)idx * (size_t)oc, oc);
        }
        for (int32_t i = 0; i < s->sb_free_n; i++) {
            int32_t idx = s->sb_free[i];
            if (idx < 0 || idx >= s->primary.grid_rows) continue;
            if (s->primary.erased && s->primary.erased[idx]) continue;
            release_cells(s, s->primary.grid + (size_t)idx * (size_t)oc, oc);
        }
    }
    buf_resize(&s->primary, oc, orows, nc, nr, cap, blank);
    if (s->alt.grid) buf_resize(&s->alt, oc, orows, nc, nr, 0, blank);
    s->active = s->in_alt ? &s->alt : &s->primary;

    sb_alloc(s, cap, nc, nr);
    if (hist && hw && s->sb_idx && s->sb_free) {
        int32_t ncopy = oc < nc ? oc : nc;
        if (slen > cap) slen = cap;
        for (int32_t i = 0; i < slen; i++) {
            if (s->sb_free_n <= 0) break;
            int32_t idx = s->sb_free[--s->sb_free_n];
            Cell *dst = s->primary.grid + (size_t)idx * (size_t)nc;
            memcpy(dst, hist + (size_t)i * (size_t)oc, (size_t)ncopy * sizeof(Cell));
            if (ncopy < nc) fill_cells(dst + ncopy, nc - ncopy, blank);
            if (s->primary.erased) s->primary.erased[idx] = 0;
            s->sb_idx[i] = idx;
            s->sb_wrap[i] = hw[i];
        }
        s->sb_len = slen;
        s->sb_head = slen < cap ? slen : 0;
        s->sb_stride = nc;
    }
    free(hist);
    free(hw);

    s->cols = nc;
    s->rows = nr;
    mark_all(s);
}

void jt_scr_init(jt_scr *s, int32_t cols, int32_t rows, int32_t sb_cap) {
    memset(s, 0, sizeof *s);
    if (cols < 2) cols = 2;
    if (rows < 1) rows = 1;
    s->cols = cols;
    s->rows = rows;
    s->auto_wrap = 1;
    s->g1 = 1;
    s->mouse_alt_scroll = 1;
    s->cursor_visible = 1;
    s->cursor_style = 2;
    s->alt_esc = 1;
    s->pen.fg = COLOR_DEFAULT;
    s->pen.bg = COLOR_DEFAULT;
    jt_defaults_reset(s);
    jt_pools_init(s);
    int32_t cap = sb_cap < 0 ? 0 : sb_cap;
    if (!buf_init(&s->primary, cols, rows, cap, blank_cell(s))) return;
    s->active = &s->primary;
    sb_alloc(s, cap, cols, rows);
}

void jt_scr_deinit(jt_scr *s) {
    sync_snap_free(s);
    buf_free(&s->primary);
    buf_free(&s->alt);
    free(s->sb_idx);
    free(s->sb_free);
    free(s->sb_wrap);
    s->sb_idx = NULL;
    s->sb_free = NULL;
    s->sb_wrap = NULL;
    s->active = NULL;
    jt_pools_deinit(s);
}

void jt_scr_ris(jt_scr *s) {
    s->active = &s->primary;
    s->in_alt = 0;
    s->pen.fg = COLOR_DEFAULT;
    s->pen.bg = COLOR_DEFAULT;
    s->pen.ul_color = COLOR_DEFAULT;
    s->pen.attrs = 0;
    if (s->pen.extra) jt_rare_release(s, s->pen.extra);
    s->pen.extra = 0;
    s->g0 = 0;
    s->g1 = 1;
    s->gl = 0;
    s->has_last_print = 0;
    s->last_print = 0;
    s->auto_wrap = 1;
    s->insert_mode = 0;
    s->origin_mode = 0;
    s->decckm = 0;
    s->deckpam = 0;
    s->cursor_visible = 1;
    s->cursor_blink = 0;
    s->alt_esc = 1;
    s->reverse_wrap = 0;
    s->reverse_wrap_ext = 0;
    s->report_theme = 0;
    s->report_vis = 0;
    s->inband_size = 0;
    s->mode_2027 = 0;
    s->xtsave_valid = 0;
    memset(s->xtsave, 0, sizeof s->xtsave);
    s->linefeed_nl = 0;
    s->cursor_style = 2;
    s->mouse_event = 0;
    s->mouse_sgr = 0;
    s->mouse_alt_scroll = 1;
    s->focus_event = 0;
    s->bracketed_paste = 0;
    s->sync_output = 0;
    s->sync_flush = 0;
    jt_sync_drop_snap(s);
    s->reverse_video = 0;
    s->primary.scroll_top = 0;
    s->primary.scroll_bottom = s->rows - 1;
    if (s->primary.tabstops) default_tabs(s->primary.tabstops, s->cols);
    s->primary.cx = 0;
    s->primary.cy = 0;
    s->primary.pending_wrap = 0;
    jt_defaults_reset(s);
    s->saved.valid = 0;
    jt_scr_ed(s, 2);
    jt_scr_clear_history(s);
}
