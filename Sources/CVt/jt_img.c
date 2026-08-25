#include "jt_img.h"
#include "jt_vt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    if (!st || idx < 0 || idx >= st->live_n + st->hist_n) return;
    jt_img_placement *p = &st->pl[idx];
    int live = p->pin.y >= 0;
    unref_image(st, p->image_id);
    int32_t n = st->live_n + st->hist_n;
    n--;
    if (idx < n) st->pl[idx] = st->pl[n];
    memset(&st->pl[n], 0, sizeof(jt_img_placement));
    if (live) st->live_n--;
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

static int evict_for(jt_img_store *st, size_t need) {
    if (!st) return 0;
    if (st->total_bytes + need <= JT_IMG_QUOTA && st->image_n < JT_IMG_MAX_IMAGES) return 1;
    int guard = JT_IMG_MAX_IMAGES + 2;
    while (guard-- > 0) {
        if (st->total_bytes + need <= JT_IMG_QUOTA && st->image_n < JT_IMG_MAX_IMAGES) return 1;
        int32_t unused = -1;
        uint64_t gen = UINT64_MAX;
        for (int32_t i = 0; i < st->image_n; i++) {
            if (st->images[i].placement_n == 0 && st->images[i].generation < gen) {
                gen = st->images[i].generation;
                unused = i;
            }
        }
        if (unused >= 0) {
            remove_image_at(st, unused);
            continue;
        }
        int32_t oldest = -1;
        gen = UINT64_MAX;
        for (int32_t i = 0; i < st->image_n; i++) {
            if (st->images[i].generation < gen) {
                gen = st->images[i].generation;
                oldest = i;
            }
        }
        if (oldest < 0) return 0;
        uint32_t id = st->images[oldest].id;
        int32_t n = st->live_n + st->hist_n;
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
    int32_t n = st->live_n + st->hist_n;
    for (int32_t i = n - 1; i >= 0; i--) {
        if (st->pl[i].image_id == id) remove_placement_at(st, i);
    }
    jt_img *im = jt_img_find(st, id);
    if (im) remove_image_at(st, (int32_t)(im - st->images));
    jt_img_sync_live(s);
}

int jt_img_add(jt_scr *s, uint32_t *id, uint32_t number, uint8_t *rgba, uint32_t w, uint32_t h) {
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
    if (nbytes > JT_IMG_MAX_BYTES) {
        free(rgba);
        return -1;
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
    if (st->live_n + st->hist_n >= JT_IMG_MAX_PLACEMENTS) {
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
        int32_t n = st->live_n + st->hist_n;
        for (int32_t i = n - 1; i >= 0; i--) {
            if (st->pl[i].image_id == id && st->pl[i].placement_id == pid && !st->pl[i].internal)
                remove_placement_at(st, i);
        }
    }

    jt_buf *b = s->active;
    int32_t x = b->cx;
    int32_t y = b->cy;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= s->cols) x = s->cols - 1;
    if (y >= s->rows) y = s->rows - 1;

    int32_t n = st->live_n + st->hist_n;
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
        b->cx = x + (int32_t)cols;
        b->cy = y + (int32_t)rows;
        if (b->cx >= s->cols) b->cx = s->cols - 1;
        if (b->cy >= s->rows) b->cy = s->rows - 1;
        if (b->cx < 0) b->cx = 0;
        if (b->cy < 0) b->cy = 0;
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
    switch (kind) {
    case 'a':
    case 0:
        return dest_intersects_live(p, s);
    case 'i':
        return i != 0 && p->image_id == i;
    case 'n':
        return I != 0 && jt_img_find(jt_img_active((jt_scr *)s), p->image_id)
            && jt_img_find(jt_img_active((jt_scr *)s), p->image_id)->number == I;
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
        return I != 0 && p->image_id != 0
            && jt_img_find(jt_img_active((jt_scr *)s), p->image_id)
            && jt_img_find(jt_img_active((jt_scr *)s), p->image_id)->number == I
            && p->placement_id == pid;
    case 'x':
        return x0 <= (int32_t)x - 1 && (int32_t)x - 1 <= x1;
    case 'y':
        return y0 <= (int32_t)y - 1 && (int32_t)y - 1 <= y1;
    case 'z':
        return p->z == z;
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
    int32_t n = st->live_n + st->hist_n;
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
    int32_t n = st->live_n + st->hist_n;
    for (int32_t i = n - 1; i >= 0; i--) {
        if (st->pl[i].pin.y < 0) remove_placement_at(st, i);
    }
    jt_img_sync_live(s);
}

static void prune_hist(jt_scr *s) {
    jt_img_store *st = jt_img_active(s);
    if (!st || st->hist_n == 0 || s->sb_len <= 0) return;
    uint64_t lo = s->lines_scrolled >= (uint64_t)s->sb_len
        ? s->lines_scrolled - (uint64_t)s->sb_len
        : 0;
    int32_t n = st->live_n + st->hist_n;
    for (int32_t i = n - 1; i >= 0; i--) {
        if (st->pl[i].pin.y < 0 && st->pl[i].pin.doc < lo) remove_placement_at(st, i);
    }
}

void jt_img_shift_region(jt_scr *s, int32_t top, int32_t bot, int dir, int sb_pushed) {
    jt_img_store *st = jt_img_active(s);
    if (!s || !st || st->live_n == 0) return;
    int32_t n = st->live_n + st->hist_n;
    if (sb_pushed) {
        for (int32_t i = n - 1; i >= 0; i--) {
            jt_img_placement *p = &st->pl[i];
            if (p->pin.y < 0) continue;
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
        if (p->pin.y < 0) continue;
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
        int32_t n = st->live_n + st->hist_n;
        for (int32_t i = n - 1; i >= 0; i--) {
            jt_img_placement *p = &st->pl[i];
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
    int32_t npl = st->live_n + st->hist_n;
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
    /* sort by z then image_id */
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
    return n;
}
