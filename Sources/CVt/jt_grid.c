#include "jt_vt.h"

#include <stdlib.h>
#include <string.h>

static void default_tabs(uint8_t *t, int32_t cols) {
    for (int32_t i = 0; i < cols; i++)
        t[i] = (i > 0 && (i % 8) == 0) ? 1 : 0;
}

static void jt_palette_reset(uint32_t pal[256]) {
    static const uint32_t ansi[16] = {
        0x000000, 0x800000, 0x008000, 0x808000,
        0x000080, 0x800080, 0x008080, 0xC0C0C0,
        0x808080, 0xFF0000, 0x00FF00, 0xFFFF00,
        0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
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

static Cell blank_cell(const jt_scr *s) {
    Cell c;
    c.content = content_scalar(0x20, WIDE_NARROW);
    c.fg = s->pen.fg;
    c.bg = s->pen.bg;
    c.attrs = s->pen.attrs;
    c.extra = 0;
    return c;
}

static int32_t phys_y(const jt_buf *b, int32_t rows, int32_t y) {
    int32_t r = b->origin + y;
    if (r >= rows) r -= rows;
    return r;
}

static Cell *row_at(jt_scr *s, int32_t y) {
    jt_buf *b = s->active;
    return b->grid + (size_t)phys_y(b, s->rows, y) * (size_t)s->cols;
}

static const Cell *row_at_c(const jt_scr *s, int32_t y) {
    const jt_buf *b = s->active;
    return b->grid + (size_t)phys_y(b, s->rows, y) * (size_t)s->cols;
}

static uint8_t *wrap_at(jt_scr *s, int32_t y) {
    jt_buf *b = s->active;
    return &b->wrap[phys_y(b, s->rows, y)];
}

static uint8_t *dirty_at(jt_scr *s, int32_t y) {
    jt_buf *b = s->active;
    return &b->dirty[phys_y(b, s->rows, y)];
}

static void mark_row(jt_scr *s, int32_t y) {
    if (y < 0 || y >= s->rows) return;
    *dirty_at(s, y) = 1;
}

static void mark_all(jt_scr *s) {
    for (int32_t y = 0; y < s->rows; y++) mark_row(s, y);
}

static void fill_cells(Cell *row, int32_t n, Cell b) {
    for (int32_t x = 0; x < n; x++) row[x] = b;
}

static void fill_row(jt_scr *s, int32_t y) {
    fill_cells(row_at(s, y), s->cols, blank_cell(s));
    *wrap_at(s, y) = 0;
    mark_row(s, y);
}

static void clamp_cursor(jt_buf *b, int32_t cols, int32_t rows) {
    if (b->cx < 0) b->cx = 0;
    if (b->cy < 0) b->cy = 0;
    if (b->cx >= cols) b->cx = cols - 1;
    if (b->cy >= rows) b->cy = rows - 1;
}

static int buf_init(jt_buf *b, int32_t cols, int32_t rows, Cell blank) {
    memset(b, 0, sizeof *b);
    b->grid = (Cell *)malloc((size_t)cols * (size_t)rows * sizeof(Cell));
    b->tabstops = (uint8_t *)malloc((size_t)cols);
    b->dirty = (uint8_t *)calloc((size_t)rows, 1);
    b->wrap = (uint8_t *)calloc((size_t)rows, 1);
    if (!b->grid || !b->tabstops || !b->dirty || !b->wrap) {
        free(b->grid);
        free(b->tabstops);
        free(b->dirty);
        free(b->wrap);
        memset(b, 0, sizeof *b);
        return 0;
    }
    fill_cells(b->grid, cols * rows, blank);
    default_tabs(b->tabstops, cols);
    memset(b->dirty, 1, (size_t)rows);
    b->scroll_bottom = rows - 1;
    return 1;
}

static void buf_free(jt_buf *b) {
    free(b->grid);
    free(b->tabstops);
    free(b->dirty);
    free(b->wrap);
    memset(b, 0, sizeof *b);
}

static void sb_alloc(jt_scr *s, int32_t cap, int32_t cols) {
    free(s->sb);
    free(s->sb_wrap);
    s->sb = NULL;
    s->sb_wrap = NULL;
    s->sb_head = 0;
    s->sb_len = 0;
    s->sb_stride = cols;
    if (cap <= 0) {
        s->scrollback_cap = 0;
        return;
    }
    s->sb = (Cell *)malloc((size_t)cap * (size_t)cols * sizeof(Cell));
    s->sb_wrap = (uint8_t *)calloc((size_t)cap, 1);
    if (!s->sb || !s->sb_wrap) {
        free(s->sb);
        free(s->sb_wrap);
        s->sb = NULL;
        s->sb_wrap = NULL;
        s->scrollback_cap = 0;
        return;
    }
    s->scrollback_cap = cap;
}

static void sb_push(jt_scr *s, const Cell *row, uint8_t wrap) {
    s->lines_scrolled++;
    if (s->scrollback_cap <= 0 || !s->sb) return;
    Cell *dst = s->sb + (size_t)s->sb_head * (size_t)s->sb_stride;
    memcpy(dst, row, (size_t)s->cols * sizeof(Cell));
    s->sb_wrap[s->sb_head] = wrap;
    s->sb_head++;
    if (s->sb_head >= s->scrollback_cap) s->sb_head = 0;
    if (s->sb_len < s->scrollback_cap) s->sb_len++;
}

static int32_t sb_phys(const jt_scr *s, int32_t i) {
    int32_t phys = s->sb_head - s->sb_len + i;
    if (phys < 0) phys += s->scrollback_cap;
    return phys;
}

static int ensure_alt(jt_scr *s) {
    if (s->alt.grid) return 1;
    return buf_init(&s->alt, s->cols, s->rows, blank_cell(s));
}

static void fix_wide_row(Cell *row, int32_t cols, Cell blank) {
    int32_t x = 0;
    while (x < cols) {
        uint32_t w = row[x].content & CONTENT_WIDE_MASK;
        if (w == WIDE_FULL) {
            if (x + 1 < cols && (row[x + 1].content & CONTENT_WIDE_MASK) == WIDE_TAIL) {
                x += 2;
                continue;
            }
            row[x] = blank;
            if (x + 1 < cols) row[x + 1] = blank;
            x += 2;
            continue;
        }
        if (w == WIDE_TAIL) {
            row[x] = blank;
            x++;
            continue;
        }
        x++;
    }
}

static void copy_rows_up(jt_scr *s, int32_t top, int32_t bot) {
    size_t n = (size_t)s->cols * sizeof(Cell);
    jt_buf *b = s->active;
    for (int32_t y = top; y < bot; y++) {
        memcpy(row_at(s, y), row_at(s, y + 1), n);
        *wrap_at(s, y) = *wrap_at(s, y + 1);
        *dirty_at(s, y) = 1;
    }
    (void)b;
}

static void copy_rows_down(jt_scr *s, int32_t top, int32_t bot) {
    size_t n = (size_t)s->cols * sizeof(Cell);
    for (int32_t y = bot; y > top; y--) {
        memcpy(row_at(s, y), row_at(s, y - 1), n);
        *wrap_at(s, y) = *wrap_at(s, y - 1);
        *dirty_at(s, y) = 1;
    }
}

static void scroll_up(jt_scr *s) {
    jt_buf *b = s->active;
    int32_t top = b->scroll_top, bot = b->scroll_bottom;
    int full = (top == 0 && bot == s->rows - 1);
    if (full) {
        if (!s->in_alt) sb_push(s, row_at(s, 0), *wrap_at(s, 0));
        else s->lines_scrolled++;
        b->origin++;
        if (b->origin >= s->rows) b->origin = 0;
        fill_row(s, s->rows - 1);
        return;
    }
    if (top == 0 && !s->in_alt) sb_push(s, row_at(s, 0), *wrap_at(s, 0));
    else if (top == 0) s->lines_scrolled++;
    if (bot > top) copy_rows_up(s, top, bot);
    fill_row(s, bot);
}

static void scroll_down(jt_scr *s) {
    jt_buf *b = s->active;
    int32_t top = b->scroll_top, bot = b->scroll_bottom;
    if (bot > top) copy_rows_down(s, top, bot);
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

void jt_scr_bs(jt_scr *s) {
    jt_buf *b = s->active;
    b->pending_wrap = 0;
    if (b->cx > 0) b->cx--;
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

static void write_one(jt_scr *s, uint32_t scalar, uint32_t wide) {
    jt_buf *b = s->active;
    consume_wrap(s);
    if (s->insert_mode) {
        jt_scr_ich(s, wide == WIDE_FULL ? 2 : 1);
    }
    Cell *cell = row_at(s, b->cy) + b->cx;
    cell->content = content_scalar(scalar, wide);
    cell->fg = s->pen.fg;
    cell->bg = s->pen.bg;
    cell->attrs = s->pen.attrs;
    cell->extra = s->pen.extra;
    mark_row(s, b->cy);
    if (b->cx + 1 >= s->cols) {
        b->cx = s->cols - 1;
        b->pending_wrap = s->auto_wrap;
    } else {
        b->cx++;
    }
}

void jt_scr_print_scalar(jt_scr *s, uint32_t scalar) {
    write_one(s, scalar, WIDE_NARROW);
}

void jt_scr_print_run(jt_scr *s, const uint8_t *p, size_t n) {
    if (s->insert_mode || n == 1) {
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
        Cell *dest = row_at(s, b->cy) + b->cx;
        for (size_t k = 0; k < take; k++) {
            dest[k].content = content_scalar(p[i + k], WIDE_NARROW);
            dest[k].fg = s->pen.fg;
            dest[k].bg = s->pen.bg;
            dest[k].attrs = s->pen.attrs;
            dest[k].extra = s->pen.extra;
        }
        mark_row(s, b->cy);
        i += take;
        if (b->cx + (int32_t)take >= s->cols) {
            b->cx = s->cols - 1;
            b->pending_wrap = s->auto_wrap;
        } else {
            b->cx += (int32_t)take;
        }
    }
}

void jt_scr_ich(jt_scr *s, int n) {
    jt_buf *b = s->active;
    if (n <= 0 || b->cx >= s->cols) return;
    Cell *row = row_at(s, b->cy);
    int32_t count = n < (s->cols - b->cx) ? n : (s->cols - b->cx);
    for (int32_t i = s->cols - 1; i >= b->cx + count; i--) {
        row[i] = row[i - count];
    }
    Cell blank = blank_cell(s);
    for (int32_t i = 0; i < count; i++) row[b->cx + i] = blank;
    fix_wide_row(row, s->cols, blank);
    *wrap_at(s, b->cy) = 0;
    mark_row(s, b->cy);
}

void jt_scr_dch(jt_scr *s, int n) {
    jt_buf *b = s->active;
    if (n <= 0 || b->cx >= s->cols) return;
    Cell *row = row_at(s, b->cy);
    int count = n < (s->cols - b->cx) ? n : (s->cols - b->cx);
    for (int i = b->cx; i < s->cols - count; i++) {
        row[i] = row[i + count];
    }
    Cell blank = blank_cell(s);
    for (int i = s->cols - count; i < s->cols; i++) row[i] = blank;
    fix_wide_row(row, s->cols, blank);
    *wrap_at(s, b->cy) = 0;
    mark_row(s, b->cy);
}

void jt_scr_ech(jt_scr *s, int n) {
    jt_buf *b = s->active;
    Cell blank = blank_cell(s);
    int count = n < (s->cols - b->cx) ? n : (s->cols - b->cx);
    if (count < 0) count = 0;
    Cell *row = row_at(s, b->cy) + b->cx;
    for (int i = 0; i < count; i++) row[i] = blank;
    fix_wide_row(row_at(s, b->cy), s->cols, blank);
    mark_row(s, b->cy);
}

void jt_scr_il(jt_scr *s, int n) {
    jt_buf *b = s->active;
    if (b->cy < b->scroll_top || b->cy > b->scroll_bottom) return;
    int nn = n < 1 ? 1 : n;
    int32_t top = b->cy, bot = b->scroll_bottom;
    for (int k = 0; k < nn; k++) {
        if (bot > top) copy_rows_down(s, top, bot);
        fill_row(s, top);
    }
}

void jt_scr_dl(jt_scr *s, int n) {
    jt_buf *b = s->active;
    if (b->cy < b->scroll_top || b->cy > b->scroll_bottom) return;
    int nn = n < 1 ? 1 : n;
    int32_t top = b->cy, bot = b->scroll_bottom;
    for (int k = 0; k < nn; k++) {
        if (bot > top) copy_rows_up(s, top, bot);
        fill_row(s, bot);
    }
}

static void fill_rect(jt_scr *s, int x1, int y1, int x2, int y2, int clear_wrap) {
    Cell blank = blank_cell(s);
    for (int y = y1; y <= y2; y++) {
        int xa = (y == y1) ? x1 : 0;
        int xb = (y == y2) ? x2 : s->cols - 1;
        Cell *row = row_at(s, y);
        for (int x = xa; x <= xb; x++) row[x] = blank;
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
    s->sb_head = 0;
    s->sb_len = 0;
    s->lines_scrolled = 0;
}

int32_t jt_scr_sb_len(const jt_scr *s) { return s->sb_len; }

Cell *jt_scr_row(jt_scr *s, int32_t y) {
    if (!s || !s->active || !s->active->grid || y < 0 || y >= s->rows) return NULL;
    return row_at(s, y);
}

void jt_scr_copy_row(const jt_scr *s, int32_t y, Cell *dst, int32_t dst_cols, Cell blank) {
    if (!dst || dst_cols <= 0) return;
    if (!s || !s->active || !s->active->grid || y < 0 || y >= s->rows) {
        for (int32_t x = 0; x < dst_cols; x++) dst[x] = blank;
        return;
    }
    int32_t n = s->cols < dst_cols ? s->cols : dst_cols;
    memcpy(dst, row_at_c(s, y), (size_t)n * sizeof(Cell));
    for (int32_t x = n; x < dst_cols; x++) dst[x] = blank;
}

void jt_scr_copy_sb_row(const jt_scr *s, int32_t i, Cell *dst, int32_t dst_cols, Cell blank) {
    if (!dst || dst_cols <= 0) return;
    if (!s || !s->sb || i < 0 || i >= s->sb_len) {
        for (int32_t x = 0; x < dst_cols; x++) dst[x] = blank;
        return;
    }
    int32_t phys = sb_phys(s, i);
    int32_t n = s->sb_stride < dst_cols ? s->sb_stride : dst_cols;
    memcpy(dst, s->sb + (size_t)phys * (size_t)s->sb_stride, (size_t)n * sizeof(Cell));
    for (int32_t x = n; x < dst_cols; x++) dst[x] = blank;
}

void jt_scr_mark_dirty(jt_scr *s, int32_t y) { mark_row(s, y); }

void jt_scr_wrap_at(jt_scr *s, int32_t y) {
    if (y < 0 || y >= s->rows) return;
    *wrap_at(s, y) = 1;
}

int jt_scr_is_wrapped(const jt_scr *s, int32_t y) {
    if (!s || !s->active || !s->active->wrap || y < 0 || y >= s->rows) return 0;
    const jt_buf *b = s->active;
    return b->wrap[phys_y(b, s->rows, y)] != 0;
}

static int buf_resize(jt_buf *b, int32_t oc, int32_t orows, int32_t nc, int32_t nr, Cell blank) {
    Cell *next = (Cell *)malloc((size_t)nc * (size_t)nr * sizeof(Cell));
    uint8_t *tabs = (uint8_t *)malloc((size_t)nc);
    uint8_t *dirty = (uint8_t *)calloc((size_t)nr, 1);
    uint8_t *wrap = (uint8_t *)calloc((size_t)nr, 1);
    if (!next || !tabs || !dirty || !wrap) {
        free(next);
        free(tabs);
        free(dirty);
        free(wrap);
        return 0;
    }
    fill_cells(next, nc * nr, blank);
    memset(dirty, 1, (size_t)nr);
    default_tabs(tabs, nc);
    int32_t copyC = oc < nc ? oc : nc;
    int32_t copyR = orows < nr ? orows : nr;
    if (b->grid) {
        for (int32_t y = 0; y < copyR; y++) {
            int32_t py = phys_y(b, orows, y);
            memcpy(next + (size_t)y * (size_t)nc, b->grid + (size_t)py * (size_t)oc,
                   (size_t)copyC * sizeof(Cell));
        }
    }
    free(b->grid);
    free(b->tabstops);
    free(b->dirty);
    free(b->wrap);
    b->grid = next;
    b->tabstops = tabs;
    b->dirty = dirty;
    b->wrap = wrap;
    b->origin = 0;
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
    Cell blank = blank_cell(s);
    int32_t oc = s->cols, orows = s->rows;
    buf_resize(&s->primary, oc, orows, nc, nr, blank);
    if (s->alt.grid) buf_resize(&s->alt, oc, orows, nc, nr, blank);
    s->active = s->in_alt ? &s->alt : &s->primary;

    if (s->scrollback_cap > 0 && s->sb) {
        int32_t cap = s->scrollback_cap;
        int32_t len = s->sb_len;
        int32_t old_stride = s->sb_stride;
        Cell *nsb = (Cell *)malloc((size_t)cap * (size_t)nc * sizeof(Cell));
        uint8_t *nw = (uint8_t *)calloc((size_t)cap, 1);
        if (nsb && nw) {
            for (int32_t i = 0; i < len; i++) {
                Cell *dst = nsb + (size_t)i * (size_t)nc;
                int32_t phys = sb_phys(s, i);
                const Cell *src = s->sb + (size_t)phys * (size_t)old_stride;
                int32_t n = old_stride < nc ? old_stride : nc;
                memcpy(dst, src, (size_t)n * sizeof(Cell));
                for (int32_t x = n; x < nc; x++) dst[x] = blank;
                nw[i] = s->sb_wrap ? s->sb_wrap[phys] : 0;
            }
            free(s->sb);
            free(s->sb_wrap);
            s->sb = nsb;
            s->sb_wrap = nw;
            s->sb_stride = nc;
            s->sb_head = len < cap ? len : 0;
        } else {
            free(nsb);
            free(nw);
        }
    }

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
    s->pen.fg = COLOR_DEFAULT;
    s->pen.bg = COLOR_DEFAULT;
    jt_palette_reset(s->palette);
    if (!buf_init(&s->primary, cols, rows, blank_cell(s))) return;
    s->active = &s->primary;
    sb_alloc(s, sb_cap < 0 ? 0 : sb_cap, cols);
}

void jt_scr_deinit(jt_scr *s) {
    buf_free(&s->primary);
    buf_free(&s->alt);
    free(s->sb);
    free(s->sb_wrap);
    s->sb = NULL;
    s->sb_wrap = NULL;
    s->active = NULL;
}
