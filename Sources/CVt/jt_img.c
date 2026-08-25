#include "jt_img.h"
#include "jt_vt.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jt_img_diacritics.inc"

static int32_t pl_count(const jt_img_store *st) {
    return st->live_n + st->hist_n + st->virtual_n;
}

static void img_free(jt_img *im) {
    free(im->rgba);
    im->rgba = NULL;
    im->nbytes = 0;
    im->width = 0;
    im->height = 0;
    im->id = 0;
    im->number = 0;
    im->placement_n = 0;
}

void jt_img_store_init(jt_img_store *st) {
    if (!st) return;
    memset(st, 0, sizeof *st);
    st->next_internal_pid = 1;
    st->next_auto_id = 2147483647u;
}

void jt_img_store_reset(jt_img_store *st) {
    if (!st) return;
    for (int32_t i = 0; i < st->image_n; i++) img_free(&st->images[i]);
    jt_img_store_init(st);
}

void jt_img_store_deinit(jt_img_store *st) {
    if (!st) return;
    for (int32_t i = 0; i < st->image_n; i++) img_free(&st->images[i]);
    memset(st, 0, sizeof *st);
}

void jt_img_abort_loading(jt_img_loading *ld) {
    if (!ld) return;
    free(ld->data);
    memset(ld, 0, sizeof *ld);
}

jt_img_store *jt_img_active(jt_scr *s) {
    if (!s) return NULL;
    return s->in_alt ? s->img_alt : s->img_primary;
}

void jt_img_sync_live(jt_scr *s) {
    if (!s) return;
    jt_img_store *st = jt_img_active(s);
    s->img_live_n = st ? st->live_n : 0;
}

int32_t jt_img_live_n(const jt_scr *s) {
    if (!s) return 0;
    const jt_img_store *st = s->in_alt ? s->img_alt : s->img_primary;
    return st ? st->live_n : 0;
}

int32_t jt_img_hist_n(const jt_scr *s) {
    if (!s) return 0;
    const jt_img_store *st = s->in_alt ? s->img_alt : s->img_primary;
    return st ? st->hist_n : 0;
}

int32_t jt_img_virtual_n(const jt_scr *s) {
    if (!s) return 0;
    const jt_img_store *st = s->in_alt ? s->img_alt : s->img_primary;
    return st ? st->virtual_n : 0;
}

void jt_scr_set_cell_px(jt_scr *s, uint32_t w, uint32_t h) {
    if (!s) return;
    s->cell_w_px = w ? w : 1;
    s->cell_h_px = h ? h : 1;
}

void jt_scr_set_kitty_graphics(jt_scr *s, int on) {
    if (!s) return;
    s->kitty_graphics = on ? 1 : 0;
}

jt_img *jt_img_find(jt_img_store *st, uint32_t id) {
    if (!st || id == 0) return NULL;
    for (int32_t i = 0; i < st->image_n; i++) {
        if (st->images[i].id == id) return &st->images[i];
    }
    return NULL;
}

jt_img *jt_img_find_number(jt_img_store *st, uint32_t number) {
    if (!st || number == 0) return NULL;
    jt_img *best = NULL;
    uint64_t gen = 0;
    for (int32_t i = 0; i < st->image_n; i++) {
        if (st->images[i].number == number && st->images[i].generation >= gen) {
            gen = st->images[i].generation;
            best = &st->images[i];
        }
    }
    return best;
}

uint32_t jt_img_alloc_id(jt_img_store *st) {
    if (!st) return 1;
    uint32_t id = st->next_auto_id;
    for (int n = 0; n < JT_IMG_MAX_IMAGES + 2; n++) {
        if (id == 0) id = 2147483647u;
        if (!jt_img_find(st, id)) {
            uint32_t next = id == 0 ? 2147483647u : id - 1;
            if (next == 0) next = 2147483647u;
            st->next_auto_id = next;
            return id;
        }
        id = id == 0 ? 2147483647u : id - 1;
    }
    return 0;
}

uint8_t *jt_img_rgb_to_rgba(const uint8_t *rgb, uint32_t w, uint32_t h) {
    size_t n = (size_t)w * (size_t)h;
    if (!rgb || n == 0 || n > (JT_IMG_MAX_BYTES / 4)) return NULL;
    uint8_t *out = (uint8_t *)malloc(n * 4);
    if (!out) return NULL;
    for (size_t i = 0; i < n; i++) {
        out[i * 4 + 0] = rgb[i * 3 + 0];
        out[i * 4 + 1] = rgb[i * 3 + 1];
        out[i * 4 + 2] = rgb[i * 3 + 2];
        out[i * 4 + 3] = 255;
    }
    return out;
}

static void unref_image(jt_img_store *st, uint32_t id) {
    jt_img *im = jt_img_find(st, id);
    if (!im || im->placement_n == 0) return;
    im->placement_n--;
}

static void remove_image_at(jt_img_store *st, int32_t idx) {
    if (!st || idx < 0 || idx >= st->image_n) return;
    if (st->images[idx].nbytes <= st->total_bytes)
        st->total_bytes -= st->images[idx].nbytes;
    else
        st->total_bytes = 0;
    img_free(&st->images[idx]);
    st->image_n--;
    if (idx < st->image_n) st->images[idx] = st->images[st->image_n];
    memset(&st->images[st->image_n], 0, sizeof(jt_img));
    st->generation++;
    st->dirty = 1;
}

static void delete_if_unused(jt_img_store *st, uint32_t id) {
    jt_img *im = jt_img_find(st, id);
    if (!im || im->placement_n != 0) return;
    int32_t idx = (int32_t)(im - st->images);
    remove_image_at(st, idx);
}

static void remove_placement_at(jt_img_store *st, int32_t idx) {
    if (!st || idx < 0 || idx >= pl_count(st)) return;
    jt_img_placement *p = &st->pl[idx];
    int virt = p->virtual;
    int live = !virt && p->pin.y >= 0;
    unref_image(st, p->image_id);
    int32_t n = pl_count(st) - 1;
    if (idx < n) st->pl[idx] = st->pl[n];
    memset(&st->pl[n], 0, sizeof(jt_img_placement));
    if (virt) st->virtual_n--;
    else if (live) st->live_n--;
    else st->hist_n--;
    st->dirty = 1;
}

static int dest_cell_rect(
    const jt_img_placement *p,
    const jt_scr *s,
    int32_t *x0,
    int32_t *y0,
    int32_t *x1,
    int32_t *y1
) {
    int32_t y;
    if (p->pin.y >= 0) y = p->pin.y;
    else y = (int32_t)((int64_t)p->pin.doc - (int64_t)s->lines_scrolled);
    int32_t cols = (int32_t)(p->cols ? p->cols : 1);
    int32_t rows = (int32_t)(p->rows ? p->rows : 1);
    *x0 = p->pin.x;
    *y0 = y;
    *x1 = p->pin.x + cols - 1;
    *y1 = y + rows - 1;
    return 1;
}

static int rect_intersects_live(const jt_scr *s, int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
    return x1 >= 0 && x0 < s->cols && y1 >= 0 && y0 < s->rows;
}

static int dest_intersects_live(const jt_img_placement *p, const jt_scr *s) {
    int32_t x0, y0, x1, y1;
    dest_cell_rect(p, s, &x0, &y0, &x1, &y1);
    return rect_intersects_live(s, x0, y0, x1, y1);
}

static uint8_t evict_pri(const jt_img *im) {
    uint8_t p = im->transient ? 0 : 1;
    if (im->placement_n > 0) p += 2;
    return p;
}

static int32_t pick_evict(const jt_img_store *st) {
    int32_t best = -1;
    uint8_t pri = 255;
    uint64_t gen = UINT64_MAX;
    uint32_t id = UINT32_MAX;
    for (int32_t i = 0; i < st->image_n; i++) {
        const jt_img *im = &st->images[i];
        uint8_t p = evict_pri(im);
        if (p > pri) continue;
        if (p < pri || im->generation < gen || (im->generation == gen && im->id < id)) {
            pri = p;
            gen = im->generation;
            id = im->id;
            best = i;
        }
    }
    return best;
}

static int evict_for(jt_img_store *st, size_t need) {
    if (!st) return 0;
    if (need > JT_IMG_QUOTA) return 0;
    int guard = JT_IMG_MAX_IMAGES + 2;
    while (guard-- > 0) {
        if (st->total_bytes + need <= JT_IMG_QUOTA && st->image_n < JT_IMG_MAX_IMAGES) return 1;
        int32_t idx = pick_evict(st);
        if (idx < 0) return 0;
        uint32_t id = st->images[idx].id;
        int32_t n = pl_count(st);
        for (int32_t i = n - 1; i >= 0; i--) {
            if (st->pl[i].image_id == id) remove_placement_at(st, i);
        }
        jt_img *im = jt_img_find(st, id);
        if (im) remove_image_at(st, (int32_t)(im - st->images));
    }
    return st->total_bytes + need <= JT_IMG_QUOTA && st->image_n < JT_IMG_MAX_IMAGES;
}

void jt_img_drop_id(jt_scr *s, uint32_t id) {
    jt_img_store *st = jt_img_active(s);
    if (!st || id == 0) return;
    int32_t n = pl_count(st);
    for (int32_t i = n - 1; i >= 0; i--) {
        if (st->pl[i].image_id == id) remove_placement_at(st, i);
    }
    jt_img *im = jt_img_find(st, id);
    if (im) remove_image_at(st, (int32_t)(im - st->images));
    jt_img_sync_live(s);
}

int jt_img_add(
    jt_scr *s,
    uint32_t *id,
    uint32_t number,
    uint8_t *rgba,
    uint32_t w,
    uint32_t h,
    uint8_t transient
) {
    jt_img_store *st = jt_img_active(s);
    if (!st || !rgba || !id || w == 0 || h == 0) {
        free(rgba);
        return -1;
    }
    if (w > JT_IMG_MAX_DIM || h > JT_IMG_MAX_DIM) {
        free(rgba);
        return -1;
    }
    size_t nbytes = (size_t)w * (size_t)h * 4;
    if (nbytes > JT_IMG_QUOTA) {
        free(rgba);
        return -2;
    }
    if (*id == 0) *id = jt_img_alloc_id(st);
    if (*id == 0) {
        free(rgba);
        return -1;
    }
    jt_img_drop_id(s, *id);
    st = jt_img_active(s);
    if (!evict_for(st, nbytes)) {
        free(rgba);
        static int once;
        if (!once) {
            once = 1;
            fputs("jetty: kitty-graphics: quota\n", stderr);
        }
        return -2;
    }
    if (st->image_n >= JT_IMG_MAX_IMAGES) {
        free(rgba);
        return -2;
    }
    jt_img *im = &st->images[st->image_n++];
    memset(im, 0, sizeof *im);
    im->id = *id;
    im->number = number;
    im->width = w;
    im->height = h;
    im->rgba = rgba;
    im->nbytes = nbytes;
    im->transient = transient ? 1 : 0;
    st->total_bytes += nbytes;
    st->generation++;
    im->generation = st->generation;
    st->dirty = 1;
    return 0;
}

static uint32_t ceil_div_u(uint32_t a, uint32_t b) {
    if (b == 0) return a;
    return (a + b - 1) / b;
}

int jt_img_put(jt_scr *s, const jt_img_loading *ld) {
    jt_img_store *st = jt_img_active(s);
    if (!s || !st || !ld) return -1;
    uint32_t id = ld->image_id;
    if (id == 0 && ld->number) {
        jt_img *by = jt_img_find_number(st, ld->number);
        if (by) id = by->id;
    }
    jt_img *im = jt_img_find(st, id);
    if (!im) return -1;
    if (pl_count(st) >= JT_IMG_MAX_PLACEMENTS) {
        static int once;
        if (!once) {
            once = 1;
            fputs("jetty: kitty-graphics: too-many-placements\n", stderr);
        }
        return -2;
    }

    uint32_t cell_w = s->cell_w_px ? s->cell_w_px : 12;
    uint32_t cell_h = s->cell_h_px ? s->cell_h_px : 24;
    uint32_t src_x = ld->src_x;
    uint32_t src_y = ld->src_y;
    uint32_t src_w = ld->src_w;
    uint32_t src_h = ld->src_h;
    if (src_x > im->width) src_x = im->width;
    if (src_y > im->height) src_y = im->height;
    if (src_w == 0) src_w = im->width - src_x;
    if (src_h == 0) src_h = im->height - src_y;
    if (src_x + src_w > im->width) src_w = im->width - src_x;
    if (src_y + src_h > im->height) src_h = im->height - src_y;
    if (src_w == 0 || src_h == 0) return -1;

    uint32_t cols = ld->cols;
    uint32_t rows = ld->rows;
    uint8_t pixel_size = 0;
    if (cols && rows) {
        /* both set */
    } else if (cols) {
        rows = (uint32_t)((double)cols * (double)src_h * (double)cell_w
                          / ((double)src_w * (double)cell_h) + 0.5);
        if (rows < 1) rows = 1;
    } else if (rows) {
        cols = (uint32_t)((double)rows * (double)src_w * (double)cell_h
                          / ((double)src_h * (double)cell_w) + 0.5);
        if (cols < 1) cols = 1;
    } else {
        pixel_size = 1;
        uint32_t dw = src_w;
        uint32_t dh = src_h;
        uint32_t maxw = (uint32_t)s->cols * cell_w;
        uint32_t maxh = (uint32_t)s->rows * cell_h;
        if (dw > maxw) dw = maxw;
        if (dh > maxh) dh = maxh;
        cols = ceil_div_u(dw, cell_w);
        rows = ceil_div_u(dh, cell_h);
        if (cols < 1) cols = 1;
        if (rows < 1) rows = 1;
    }

    uint32_t off_x = ld->off_x;
    uint32_t off_y = ld->off_y;
    if (off_x >= cell_w) off_x = cell_w ? cell_w - 1 : 0;
    if (off_y >= cell_h) off_y = cell_h ? cell_h - 1 : 0;

    uint32_t pid = ld->placement_id;
    uint8_t internal = 0;
    if (pid == 0) {
        pid = st->next_internal_pid++;
        if (st->next_internal_pid == 0) st->next_internal_pid = 1;
        internal = 1;
    } else {
        int32_t n = pl_count(st);
        for (int32_t i = n - 1; i >= 0; i--) {
            if (st->pl[i].image_id == id && st->pl[i].placement_id == pid && !st->pl[i].internal)
                remove_placement_at(st, i);
        }
    }

    if (ld->unicode) {
        jt_img_placement *p = &st->pl[pl_count(st)];
        memset(p, 0, sizeof *p);
        p->image_id = id;
        p->placement_id = pid;
        p->internal = internal;
        p->virtual = 1;
        p->pixel_size = pixel_size;
        p->z = ld->z;
        p->src_x = src_x;
        p->src_y = src_y;
        p->src_w = src_w;
        p->src_h = src_h;
        p->cols = cols;
        p->rows = rows;
        p->off_x = off_x;
        p->off_y = off_y;
        st->virtual_n++;
        im->placement_n++;
        st->dirty = 1;
        jt_img_sync_live(s);
        return 0;
    }

    jt_buf *b = s->active;
    int32_t x = b->cx;
    int32_t y = b->cy;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= s->cols) x = s->cols - 1;
    if (y >= s->rows) y = s->rows - 1;

    int32_t n = pl_count(st);
    jt_img_placement *p = &st->pl[n];
    memset(p, 0, sizeof *p);
    p->image_id = id;
    p->placement_id = pid;
    p->internal = internal;
    p->pixel_size = pixel_size;
    p->z = ld->z;
    p->src_x = src_x;
    p->src_y = src_y;
    p->src_w = src_w;
    p->src_h = src_h;
    p->cols = cols;
    p->rows = rows;
    p->off_x = off_x;
    p->off_y = off_y;
    p->pin.x = x;
    p->pin.y = y;
    p->pin.doc = s->lines_scrolled + (uint64_t)y;
    st->live_n++;
    im->placement_n++;
    st->dirty = 1;
    jt_img_sync_live(s);

    if (!ld->no_cursor) {
        /* Kitty: x += cols, y += rows-1, then the screen keeps the
         * cursor in bounds (IND / wrap). Ghostty: index (rows-1) times,
         * plus once if x+cols hits the right edge, cap extra scrolls
         * at one screen. Then set x to start+cols, or 0 on wrap. */
        int32_t target_x = x + (int32_t)cols;
        int wraps = target_x >= s->cols;
        int32_t requested = (int32_t)rows - 1 + (wraps ? 1 : 0);
        if (requested < 0) requested = 0;
        int32_t top = b->scroll_top;
        int32_t bot = b->scroll_bottom;
        int32_t before = 0;
        if (b->cy >= top && b->cy <= bot) before = bot - b->cy;
        int32_t cap = before + s->rows;
        int32_t nmove = requested < cap ? requested : cap;
        for (int32_t i = 0; i < nmove; i++) jt_scr_index(s);
        b->pending_wrap = 0;
        b->cx = wraps ? 0 : target_x;
        if (b->cx >= s->cols) b->cx = s->cols - 1;
        if (b->cx < 0) b->cx = 0;
    }
    return 0;
}

static int match_delete(
    const jt_img_placement *p,
    const jt_scr *s,
    uint8_t d,
    uint32_t i,
    uint32_t I,
    uint32_t pid,
    uint32_t x,
    uint32_t y,
    int32_t z
) {
    int32_t x0, y0, x1, y1;
    dest_cell_rect(p, s, &x0, &y0, &x1, &y1);
    uint8_t kind = d;
    if (kind >= 'A' && kind <= 'Z') kind = (uint8_t)(kind - 'A' + 'a');
    /* Virtuals: only i/I n/N r/R (image identity), not screen-geometry deletes. */
    if (p->virtual) {
        if (kind != 'i' && kind != 'n' && kind != 'r') return 0;
    }
    switch (kind) {
    case 'a':
    case 0:
        return dest_intersects_live(p, s);
    case 'i':
        if (i == 0 || p->image_id != i) return 0;
        if (pid && (p->internal || p->placement_id != pid)) return 0;
        return 1;
    case 'n': {
        if (I == 0) return 0;
        jt_img *newest = jt_img_find_number(jt_img_active((jt_scr *)s), I);
        if (!newest || p->image_id != newest->id) return 0;
        if (pid && (p->internal || p->placement_id != pid)) return 0;
        return 1;
    }
    case 'c':
        return dest_intersects_live(p, s)
            && x0 <= s->active->cx && s->active->cx <= x1
            && y0 <= s->active->cy && s->active->cy <= y1;
    case 'p': {
        int32_t cx = (int32_t)x - 1;
        int32_t cy = (int32_t)y - 1;
        if (x == 0 && y == 0) {
            cx = s->active->cx;
            cy = s->active->cy;
        }
        return x0 <= cx && cx <= x1 && y0 <= cy && cy <= y1;
    }
    case 'q':
        return p->z == z && x0 <= (int32_t)x - 1 && (int32_t)x - 1 <= x1
            && y0 <= (int32_t)y - 1 && (int32_t)y - 1 <= y1;
    case 'r':
        /* Image-id range [x, y]. Inverted or empty matches nothing (Kitty). */
        if (x == 0 || y == 0 || x > y) return 0;
        return p->image_id >= x && p->image_id <= y;
    case 'x':
        return x0 <= (int32_t)x - 1 && (int32_t)x - 1 <= x1;
    case 'y':
        return y0 <= (int32_t)y - 1 && (int32_t)y - 1 <= y1;
    case 'z':
        return !p->virtual && p->z == z;
    default:
        return 0;
    }
}

int jt_img_delete(
    jt_scr *s,
    uint8_t d,
    uint32_t i,
    uint32_t I,
    uint32_t p,
    uint32_t x,
    uint32_t y,
    int32_t z
) {
    jt_img_store *st = jt_img_active(s);
    if (!st) return 0;
    if (d == 'f' || d == 'F') return -3;
    int upper = d >= 'A' && d <= 'Z';
    int32_t n = pl_count(st);
    uint32_t touched[JT_IMG_MAX_IMAGES];
    int tn = 0;
    for (int32_t k = n - 1; k >= 0; k--) {
        if (!match_delete(&st->pl[k], s, d, i, I, p, x, y, z)) continue;
        uint32_t id = st->pl[k].image_id;
        remove_placement_at(st, k);
        if (upper && tn < JT_IMG_MAX_IMAGES) touched[tn++] = id;
    }
    if (d == 'i' || d == 'I') {
        if (i) {
            /* also drop unused image even if it had no placements */
            if (upper) delete_if_unused(st, i);
        }
    }
    if (upper) {
        for (int t = 0; t < tn; t++) delete_if_unused(st, touched[t]);
        if ((d == 'I' || d == 'i') && i) delete_if_unused(st, i);
    }
    jt_img_sync_live(s);
    return 0;
}

void jt_img_clear_visible(jt_scr *s) {
    jt_img_delete(s, 'a', 0, 0, 0, 0, 0, 0);
}

void jt_img_clear_history_pins(jt_scr *s) {
    jt_img_store *st = jt_img_active(s);
    if (!st || st->hist_n == 0) return;
    int32_t n = pl_count(st);
    for (int32_t i = n - 1; i >= 0; i--) {
        if (!st->pl[i].virtual && st->pl[i].pin.y < 0) remove_placement_at(st, i);
    }
    jt_img_sync_live(s);
}

static void prune_hist(jt_scr *s) {
    jt_img_store *st = jt_img_active(s);
    if (!st || st->hist_n == 0 || s->sb_len <= 0) return;
    uint64_t lo = s->lines_scrolled >= (uint64_t)s->sb_len
        ? s->lines_scrolled - (uint64_t)s->sb_len
        : 0;
    int32_t n = pl_count(st);
    for (int32_t i = n - 1; i >= 0; i--) {
        if (!st->pl[i].virtual && st->pl[i].pin.y < 0 && st->pl[i].pin.doc < lo)
            remove_placement_at(st, i);
    }
}

void jt_img_shift_region(jt_scr *s, int32_t top, int32_t bot, int dir, int sb_pushed) {
    jt_img_store *st = jt_img_active(s);
    if (!s || !st || st->live_n == 0) return;
    int32_t n = pl_count(st);
    if (sb_pushed) {
        for (int32_t i = n - 1; i >= 0; i--) {
            jt_img_placement *p = &st->pl[i];
            if (p->virtual || p->pin.y < 0) continue;
            if (p->pin.y == 0) {
                p->pin.y = -1;
                p->pin.doc = s->lines_scrolled ? s->lines_scrolled - 1 : 0;
                st->live_n--;
                st->hist_n++;
                st->dirty = 1;
            } else {
                p->pin.y--;
                st->dirty = 1;
            }
        }
        if (s->sb_len == s->scrollback_cap) prune_hist(s);
        jt_img_sync_live(s);
        return;
    }
    for (int32_t i = n - 1; i >= 0; i--) {
        jt_img_placement *p = &st->pl[i];
        if (p->virtual || p->pin.y < 0) continue;
        if (p->pin.y < top || p->pin.y > bot) continue;
        p->pin.y += dir;
        if (p->pin.y < top || p->pin.y > bot) {
            remove_placement_at(st, i);
            continue;
        }
        int32_t y1 = p->pin.y + (int32_t)p->rows - 1;
        if (y1 > bot) {
            int32_t rows = bot - p->pin.y + 1;
            if (rows <= 0) {
                remove_placement_at(st, i);
                continue;
            }
            p->rows = (uint32_t)rows;
        }
        st->dirty = 1;
    }
    jt_img_sync_live(s);
}

void jt_img_on_resize(jt_scr *s, int32_t old_cols, int32_t old_rows, int32_t nc, int32_t nr) {
    (void)old_cols;
    (void)old_rows;
    if (!s) return;
    jt_img_store *stores[2] = { s->img_primary, s->img_alt };
    for (int k = 0; k < 2; k++) {
        jt_img_store *st = stores[k];
        if (!st) continue;
        int32_t n = pl_count(st);
        for (int32_t i = n - 1; i >= 0; i--) {
            jt_img_placement *p = &st->pl[i];
            if (p->virtual) continue;
            if (p->pin.x >= nc) {
                remove_placement_at(st, i);
                continue;
            }
            if (p->pin.y >= 0 && p->pin.y >= nr) {
                remove_placement_at(st, i);
                continue;
            }
            if (p->pin.x + (int32_t)p->cols > nc) {
                int32_t cols = nc - p->pin.x;
                if (cols <= 0) {
                    remove_placement_at(st, i);
                    continue;
                }
                p->cols = (uint32_t)cols;
            }
            if (p->pin.y >= 0 && p->pin.y + (int32_t)p->rows > nr) {
                int32_t rows = nr - p->pin.y;
                if (rows <= 0) {
                    remove_placement_at(st, i);
                    continue;
                }
                p->rows = (uint32_t)rows;
            }
        }
    }
    jt_img_sync_live(s);
}

int32_t jt_img_snapshot(
    const jt_scr *s,
    int32_t integer_row,
    int32_t paint_rows,
    uint32_t cell_w,
    uint32_t cell_h,
    jt_img_snap *out,
    int32_t cap
) {
    if (!s || !out || cap <= 0 || paint_rows <= 0) return 0;
    const jt_img_store *st = s->in_alt ? s->img_alt : s->img_primary;
    if (!st) return 0;
    int32_t npl = pl_count(st);
    if (npl == 0) return 0;
    if (cell_w == 0) cell_w = 1;
    if (cell_h == 0) cell_h = 1;
    uint64_t lo = 0;
    uint64_t view_start_doc;
    if (s->in_alt) {
        view_start_doc = s->lines_scrolled;
    } else {
        if (s->lines_scrolled >= (uint64_t)s->sb_len) lo = s->lines_scrolled - (uint64_t)s->sb_len;
        view_start_doc = lo + (uint64_t)(integer_row < 0 ? 0 : integer_row);
    }
    int32_t vw = s->cols * (int32_t)cell_w;
    int32_t vh = paint_rows * (int32_t)cell_h;
    int32_t n = 0;
    for (int32_t i = 0; i < npl; i++) {
        const jt_img_placement *p = &st->pl[i];
        if (p->virtual) continue;
        const jt_img *im = NULL;
        for (int32_t k = 0; k < st->image_n; k++) {
            if (st->images[k].id == p->image_id) {
                im = &st->images[k];
                break;
            }
        }
        if (!im || !im->rgba) continue;
        uint64_t origin_doc = p->pin.y >= 0
            ? s->lines_scrolled + (uint64_t)p->pin.y
            : p->pin.doc;
        int32_t paint_row = (int32_t)((int64_t)origin_doc - (int64_t)view_start_doc);
        uint32_t off_x = p->off_x;
        uint32_t off_y = p->off_y;
        if (off_x >= cell_w) off_x = cell_w - 1;
        if (off_y >= cell_h) off_y = cell_h - 1;
        int32_t ox0 = p->pin.x * (int32_t)cell_w + (int32_t)off_x;
        int32_t oy0 = paint_row * (int32_t)cell_h + (int32_t)off_y;
        int32_t sx0, sy0;
        if (p->pixel_size) {
            sx0 = (int32_t)p->src_w;
            sy0 = (int32_t)p->src_h;
        } else {
            sx0 = (int32_t)p->cols * (int32_t)cell_w - (int32_t)off_x;
            sy0 = (int32_t)p->rows * (int32_t)cell_h - (int32_t)off_y;
        }
        if (sx0 <= 0 || sy0 <= 0) continue;
        int32_t ix0 = ox0 > 0 ? ox0 : 0;
        int32_t iy0 = oy0 > 0 ? oy0 : 0;
        int32_t ix1 = ox0 + sx0 < vw ? ox0 + sx0 : vw;
        int32_t iy1 = oy0 + sy0 < vh ? oy0 + sy0 : vh;
        if (ix1 <= ix0 || iy1 <= iy0) continue;
        int32_t csx = ix1 - ix0;
        int32_t csy = iy1 - iy0;
        double u0 = (double)p->src_x + (double)(ix0 - ox0) * (double)p->src_w / (double)sx0;
        double v0 = (double)p->src_y + (double)(iy0 - oy0) * (double)p->src_h / (double)sy0;
        double u1 = (double)p->src_x + (double)(ix1 - ox0) * (double)p->src_w / (double)sx0;
        double v1 = (double)p->src_y + (double)(iy1 - oy0) * (double)p->src_h / (double)sy0;
        if (u0 < 0) u0 = 0;
        if (v0 < 0) v0 = 0;
        if (u1 > (double)im->width) u1 = (double)im->width;
        if (v1 > (double)im->height) v1 = (double)im->height;
        if (n >= cap) {
            static int once;
            if (!once) {
                once = 1;
                fputs("jetty: kitty-graphics: snapshot-cap\n", stderr);
            }
            break;
        }
        jt_img_snap *o = &out[n++];
        o->image_id = im->id;
        o->generation = im->generation;
        o->z = p->z;
        o->ox = ix0;
        o->oy = iy0;
        o->sx = csx;
        o->sy = csy;
        o->u0 = (uint16_t)(u0 < 0 ? 0 : u0 > 65535 ? 65535 : u0);
        o->v0 = (uint16_t)(v0 < 0 ? 0 : v0 > 65535 ? 65535 : v0);
        o->u1 = (uint16_t)(u1 < 0 ? 0 : u1 > 65535 ? 65535 : u1);
        o->v1 = (uint16_t)(v1 < 0 ? 0 : v1 > 65535 ? 65535 : v1);
        o->width = im->width;
        o->height = im->height;
        o->rgba = im->rgba;
    }
    jt_img_sort_snaps(out, n);
    return n;
}

void jt_img_sort_snaps(jt_img_snap *out, int32_t n) {
    if (!out || n <= 1) return;
    for (int32_t a = 0; a < n; a++) {
        for (int32_t b = a + 1; b < n; b++) {
            if (out[b].z < out[a].z
                || (out[b].z == out[a].z && out[b].image_id < out[a].image_id)) {
                jt_img_snap t = out[a];
                out[a] = out[b];
                out[b] = t;
            }
        }
    }
}

static int dia_index(uint32_t cp) {
    int lo = 0, hi = JT_IMG_DIACRITIC_N - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        if (jt_img_diacritics[mid] == cp) return mid;
        if (jt_img_diacritics[mid] < cp) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

static uint32_t color_to_id(uint32_t c) {
    uint32_t t = color_type(c);
    if (t == 0) return 0;
    if (t == 1) return c & 0xFFu;
    return c & 0xFFFFFFu;
}

static const jt_img_placement *placeholder_target(
    const jt_img_store *st,
    uint32_t image_id,
    uint32_t pid
) {
    int32_t n = pl_count(st);
    if (pid) {
        for (int32_t i = 0; i < n; i++) {
            const jt_img_placement *p = &st->pl[i];
            if (p->image_id == image_id && !p->internal && p->placement_id == pid)
                return p;
        }
        return NULL;
    }
    const jt_img_placement *best = NULL;
    for (int32_t i = 0; i < n; i++) {
        const jt_img_placement *p = &st->pl[i];
        if (p->image_id != image_id || !p->virtual) continue;
        if (!best) {
            best = p;
            continue;
        }
        int p_ext = !p->internal;
        int b_ext = !best->internal;
        if (p_ext != b_ext) {
            if (p_ext) best = p;
        } else if (p->placement_id < best->placement_id) {
            best = p;
        }
    }
    return best;
}

static const jt_img *img_by_id(const jt_img_store *st, uint32_t id) {
    for (int32_t k = 0; k < st->image_n; k++) {
        if (st->images[k].id == id) return &st->images[k];
    }
    return NULL;
}

typedef struct {
    uint32_t image_id_low;
    int has_high;
    uint8_t image_id_high;
    int has_pid;
    uint32_t placement_id;
    int has_row, has_col;
    uint32_t row, col;
    uint32_t width;
    int32_t x, y;
} ph_run;

static int parse_placeholder(
    const jt_scr *s,
    const Cell *c,
    ph_run *out
) {
    uint32_t cps[16];
    int n = 0;
    if ((c->content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME) {
        uint16_t gn = 0;
        const uint32_t *old = jt_grapheme_get(s, c->content & CONTENT_PAYLOAD, &gn);
        if (!old || gn == 0 || old[0] != 0x10EEEEu) return 0;
        n = gn > 16 ? 16 : (int)gn;
        memcpy(cps, old, (size_t)n * sizeof(uint32_t));
    } else if ((c->content & CONTENT_PAYLOAD) == 0x10EEEEu) {
        cps[0] = 0x10EEEEu;
        n = 1;
    } else {
        return 0;
    }
    memset(out, 0, sizeof *out);
    out->width = 1;
    out->image_id_low = color_to_id(c->fg);
    if (c->extra) {
        jt_rare rare;
        if (jt_rare_get(s, c->extra, &rare) == 1) {
            uint32_t pid = color_to_id(rare.ul_color);
            if (pid) {
                out->has_pid = 1;
                out->placement_id = pid;
            }
        }
    }
    if (n > 1) {
        int idx = dia_index(cps[1]);
        if (idx >= 0) {
            out->has_row = 1;
            out->row = (uint32_t)idx;
        }
        if (n > 2) {
            idx = dia_index(cps[2]);
            if (idx >= 0) {
                out->has_col = 1;
                out->col = (uint32_t)idx;
            }
            if (n > 3) {
                idx = dia_index(cps[3]);
                if (idx >= 0 && idx <= 255) {
                    out->has_high = 1;
                    out->image_id_high = (uint8_t)idx;
                }
            }
        }
    }
    return 1;
}

static int run_can_append(const ph_run *a, const ph_run *b) {
    if (a->image_id_low != b->image_id_low) return 0;
    if (a->has_pid != b->has_pid) return 0;
    if (a->has_pid && a->placement_id != b->placement_id) return 0;
    if (b->has_row && b->row != a->row) return 0;
    if (b->has_col && b->col != a->col + a->width) return 0;
    if (b->has_high && (!a->has_high || b->image_id_high != a->image_id_high)) return 0;
    return 1;
}

static int virt_run_snap(
    const jt_img *im,
    const jt_img_placement *vp,
    uint32_t frag_col,
    uint32_t frag_row,
    uint32_t frag_w,
    int32_t paint_x,
    int32_t paint_y,
    uint32_t cell_w,
    uint32_t cell_h,
    int32_t vw,
    int32_t vh,
    jt_img_snap *o
) {
    uint32_t grid_rows = vp->rows;
    uint32_t grid_cols = vp->cols;
    if (grid_rows == 0) grid_rows = (im->height + cell_h - 1) / cell_h;
    if (grid_cols == 0) grid_cols = (im->width + cell_w - 1) / cell_w;
    if (grid_rows == 0 || grid_cols == 0) return 0;

    double img_w = (double)im->width;
    double img_h = (double)im->height;
    double p_rows_px = (double)grid_rows * (double)cell_h;
    double p_cols_px = (double)grid_cols * (double)cell_w;
    double x_scale, y_scale, pad_x = 0, pad_y = 0;
    if (img_w * p_rows_px > img_h * p_cols_px) {
        x_scale = p_cols_px / (img_w > 0 ? img_w : 1);
        y_scale = x_scale;
        pad_y = (p_rows_px - img_h * y_scale) / 2;
    } else {
        y_scale = p_rows_px / (img_h > 0 ? img_h : 1);
        x_scale = y_scale;
        pad_x = (p_cols_px - img_w * x_scale) / 2;
    }
    if (x_scale <= 0 || y_scale <= 0) return 0;

    double img_x_off = pad_x / x_scale;
    double img_y_off = pad_y / y_scale;
    double scaled_w = img_w + img_x_off * 2;
    double scaled_h = img_h + img_y_off * 2;
    double src_w = scaled_w * ((double)frag_w / (double)grid_cols);
    double src_h = scaled_h * (1.0 / (double)grid_rows);
    double src_x = scaled_w * ((double)frag_col / (double)grid_cols);
    double src_y = scaled_h * ((double)frag_row / (double)grid_rows);
    double dest_w = (double)frag_w * (double)cell_w;
    double dest_h = (double)cell_h;
    double x_offset = 0, y_offset = 0;

    if (src_y < img_y_off) {
        double offset = img_y_off - src_y;
        src_h -= offset;
        y_offset = offset;
        dest_h -= offset * y_scale;
        src_y = 0;
        if (src_h > img_h) {
            src_h = img_h;
            dest_h = img_h * y_scale;
        }
    } else if (src_y + src_h > scaled_h - img_y_off) {
        src_y -= img_y_off;
        src_h = scaled_h - img_y_off - src_y - img_y_off;
        dest_h = src_h * y_scale;
    } else {
        src_y -= img_y_off;
    }

    if (src_x < img_x_off) {
        double offset = img_x_off - src_x;
        src_w -= offset;
        x_offset = offset;
        dest_w -= offset * x_scale;
        src_x = 0;
        if (src_w > img_w) {
            src_w = img_w;
            dest_w = img_w * x_scale;
        }
    } else if (src_x + src_w > scaled_w - img_x_off) {
        src_x -= img_x_off;
        src_w = scaled_w - img_x_off - src_x - img_x_off;
        dest_w = src_w * x_scale;
    } else {
        src_x -= img_x_off;
    }

    if (src_w <= 0 || src_h <= 0) return 0;
    x_offset *= x_scale;
    y_offset *= y_scale;

    int32_t ox0 = paint_x * (int32_t)cell_w + (int32_t)lround(x_offset);
    int32_t oy0 = paint_y * (int32_t)cell_h + (int32_t)lround(y_offset);
    int32_t sx0 = (int32_t)lround(dest_w);
    int32_t sy0 = (int32_t)lround(dest_h);
    if (sx0 <= 0 || sy0 <= 0) return 0;
    int32_t ix0 = ox0 > 0 ? ox0 : 0;
    int32_t iy0 = oy0 > 0 ? oy0 : 0;
    int32_t ix1 = ox0 + sx0 < vw ? ox0 + sx0 : vw;
    int32_t iy1 = oy0 + sy0 < vh ? oy0 + sy0 : vh;
    if (ix1 <= ix0 || iy1 <= iy0) return 0;
    double u0 = src_x + (double)(ix0 - ox0) * src_w / (double)sx0;
    double v0 = src_y + (double)(iy0 - oy0) * src_h / (double)sy0;
    double u1 = src_x + (double)(ix1 - ox0) * src_w / (double)sx0;
    double v1 = src_y + (double)(iy1 - oy0) * src_h / (double)sy0;
    if (u0 < 0) u0 = 0;
    if (v0 < 0) v0 = 0;
    if (u1 > img_w) u1 = img_w;
    if (v1 > img_h) v1 = img_h;
    o->image_id = im->id;
    o->generation = im->generation;
    o->z = vp->z;
    o->ox = ix0;
    o->oy = iy0;
    o->sx = ix1 - ix0;
    o->sy = iy1 - iy0;
    o->u0 = (uint16_t)(u0 < 0 ? 0 : u0 > 65535 ? 65535 : u0);
    o->v0 = (uint16_t)(v0 < 0 ? 0 : v0 > 65535 ? 65535 : v0);
    o->u1 = (uint16_t)(u1 < 0 ? 0 : u1 > 65535 ? 65535 : u1);
    o->v1 = (uint16_t)(v1 < 0 ? 0 : v1 > 65535 ? 65535 : v1);
    o->width = im->width;
    o->height = im->height;
    o->rgba = im->rgba;
    return 1;
}

static void emit_run(
    const jt_scr *s,
    const jt_img_store *st,
    ph_run *run,
    int32_t cols,
    uint32_t cell_w,
    uint32_t cell_h,
    int32_t vw,
    int32_t vh,
    uint8_t *hide,
    jt_img_snap *out,
    int32_t cap,
    int32_t *n
) {
    uint32_t image_id = run->image_id_low;
    if (run->has_high) image_id |= ((uint32_t)run->image_id_high) << 24;
    if (image_id == 0) return;
    uint32_t pid = run->has_pid ? run->placement_id : 0;
    const jt_img_placement *vp = placeholder_target(st, image_id, pid);
    const jt_img *im = img_by_id(st, image_id);
    if (!vp || !im || !im->rgba) return;
    if (hide) {
        for (uint32_t i = 0; i < run->width; i++) {
            int32_t x = run->x + (int32_t)i;
            if (x >= 0 && x < cols)
                hide[run->y * cols + x] = 1;
        }
    }
    if (*n >= cap) return;
    if (virt_run_snap(
            im, vp, run->col, run->row, run->width,
            run->x, run->y, cell_w, cell_h, vw, vh, &out[*n]
        ))
        (*n)++;
    (void)s;
}

int32_t jt_img_placeholder_scan(
    const jt_scr *s,
    const Cell *paint,
    int32_t cols,
    int32_t paint_rows,
    uint32_t cell_w,
    uint32_t cell_h,
    uint8_t *hide,
    jt_img_snap *out,
    int32_t cap
) {
    if (!s || !paint || !out || cap <= 0 || cols <= 0 || paint_rows <= 0) return 0;
    const jt_img_store *st = s->in_alt ? s->img_alt : s->img_primary;
    if (!st || st->virtual_n == 0) return 0;
    if (cell_w == 0) cell_w = 1;
    if (cell_h == 0) cell_h = 1;
    int32_t vw = cols * (int32_t)cell_w;
    int32_t vh = paint_rows * (int32_t)cell_h;
    int32_t n = 0;
    for (int32_t y = 0; y < paint_rows; y++) {
        int have = 0;
        ph_run run;
        memset(&run, 0, sizeof run);
        for (int32_t x = 0; x < cols; x++) {
            ph_run cur;
            if (!parse_placeholder(s, &paint[y * cols + x], &cur)) {
                if (have) {
                    emit_run(s, st, &run, cols, cell_w, cell_h, vw, vh, hide, out, cap, &n);
                    have = 0;
                }
                continue;
            }
            cur.x = x;
            cur.y = y;
            if (have && run_can_append(&run, &cur)) {
                run.width++;
                continue;
            }
            if (have) emit_run(s, st, &run, cols, cell_w, cell_h, vw, vh, hide, out, cap, &n);
            if (!cur.has_row) cur.row = 0;
            if (!cur.has_col) cur.col = 0;
            run = cur;
            have = 1;
        }
        if (have) emit_run(s, st, &run, cols, cell_w, cell_h, vw, vh, hide, out, cap, &n);
    }
    return n;
}
