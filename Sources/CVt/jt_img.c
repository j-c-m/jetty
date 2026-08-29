#include "jt_img.h"
#include "jt_vt.h"

#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jt_img_diacritics.inc"

static int32_t pl_count(const jt_img_store *st) {
    return st->live_n + st->hist_n + st->virtual_n + st->relative_n;
}

static size_t img_storage_size(const jt_img *im) {
    size_t n = im->nbytes;
    size_t one = (size_t)im->width * (size_t)im->height * 4;
    if (im->frame_n > 0 && one) n += (size_t)im->frame_n * one;
    return n;
}

static void img_free(jt_img *im) {
    free(im->rgba);
    if (im->frames) {
        for (int32_t i = 0; i < im->frame_n; i++) free(im->frames[i].rgba);
        free(im->frames);
    }
    memset(im, 0, sizeof *im);
}

static const uint8_t *img_display_rgba(const jt_img *im) {
    if (!im) return NULL;
    if (im->has_anim && im->current_index > 0
        && im->current_index <= (uint32_t)im->frame_n) {
        uint8_t *p = im->frames[im->current_index - 1].rgba;
        if (p) return p;
    }
    return im->rgba;
}

static uint8_t *img_frame_ptr(jt_img *im, uint32_t number) {
    if (!im || number == 0) return NULL;
    if (number == 1) return im->rgba;
    if (number - 2 >= (uint32_t)im->frame_n) return NULL;
    return im->frames[number - 2].rgba;
}

static uint32_t img_frame_count(const jt_img *im) {
    return im ? (uint32_t)im->frame_n + 1 : 0;
}

static uint32_t gap_at(const jt_img *im, uint32_t index) {
    if (!im) return 0;
    if (index == 0) return im->root_gap_ms;
    if (index > (uint32_t)im->frame_n) return 0;
    return im->frames[index - 1].gap_ms;
}

static void set_gap_at(jt_img *im, uint32_t index, uint32_t gap_ms) {
    if (!im) return;
    if (index == 0) im->root_gap_ms = gap_ms;
    else if (index <= (uint32_t)im->frame_n)
        im->frames[index - 1].gap_ms = gap_ms;
}

static uint64_t anim_duration_ms(const jt_img *im) {
    uint64_t total = im->root_gap_ms;
    for (int32_t i = 0; i < im->frame_n; i++) total += im->frames[i].gap_ms;
    return total;
}

static uint64_t add_sat_u64(uint64_t a, uint64_t b) {
    if (a > UINT64_MAX - b) return UINT64_MAX;
    return a + b;
}

static void mark_img_content(jt_img_store *st, jt_img *im) {
    st->generation++;
    im->generation = st->generation;
    st->dirty = 1;
}

static void compose_row(
    uint8_t *dst,
    const uint8_t *src,
    uint32_t n,
    int overwrite
) {
    if (overwrite) {
        memcpy(dst, src, (size_t)n * 4);
        return;
    }
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t *s = src + (size_t)i * 4;
        uint8_t *d = dst + (size_t)i * 4;
        uint8_t sa = s[3];
        if (sa == 0) continue;
        if (sa == 255 || d[3] == 0) {
            memcpy(d, s, 4);
            continue;
        }
        uint8_t inv = (uint8_t)(255 - sa);
        for (int c = 0; c < 4; c++) {
            uint32_t v = (uint32_t)s[c] + ((uint32_t)d[c] * inv + 127u) / 255u;
            d[c] = (uint8_t)(v > 255u ? 255u : v);
        }
    }
}

static void compose_rect(
    uint8_t *dst,
    uint32_t dw,
    uint32_t dh,
    const uint8_t *src,
    uint32_t sw,
    uint32_t sh,
    uint32_t x,
    uint32_t y,
    int overwrite
) {
    if (x >= dw || y >= dh || sw == 0 || sh == 0) return;
    uint32_t width = sw < dw - x ? sw : dw - x;
    uint32_t height = sh < dh - y ? sh : dh - y;
    for (uint32_t row = 0; row < height; row++) {
        uint8_t *dp = dst + ((size_t)(y + row) * dw + x) * 4;
        const uint8_t *sp = src + (size_t)row * sw * 4;
        compose_row(dp, sp, width, overwrite);
    }
}

static void compose_canvas_rect(
    uint8_t *dst,
    const uint8_t *src,
    uint32_t cw,
    uint32_t width,
    uint32_t height,
    uint32_t sx,
    uint32_t sy,
    uint32_t dx,
    uint32_t dy,
    int overwrite
) {
    for (uint32_t row = 0; row < height; row++) {
        uint8_t *dp = dst + ((size_t)(dy + row) * cw + dx) * 4;
        const uint8_t *sp = src + ((size_t)(sy + row) * cw + sx) * 4;
        compose_row(dp, sp, width, overwrite);
    }
}

static void fill_bg(uint8_t *data, size_t n, uint32_t y) {
    if (y == 0) {
        memset(data, 0, n);
        return;
    }
    uint8_t px[4] = {
        (uint8_t)(y >> 24),
        (uint8_t)(y >> 16),
        (uint8_t)(y >> 8),
        (uint8_t)y
    };
    jt_img_premultiply_rgba(px, 1);
    for (size_t i = 0; i + 4 <= n; i += 4) {
        data[i + 0] = px[0];
        data[i + 1] = px[1];
        data[i + 2] = px[2];
        data[i + 3] = px[3];
    }
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

int32_t jt_img_relative_n(const jt_scr *s) {
    if (!s) return 0;
    const jt_img_store *st = s->in_alt ? s->img_alt : s->img_primary;
    return st ? st->relative_n : 0;
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

void jt_img_premultiply_rgba(uint8_t *rgba, size_t npx) {
    if (!rgba || npx == 0) return;
    for (size_t i = 0; i < npx; i++) {
        uint8_t *p = rgba + i * 4;
        uint8_t a = p[3];
        if (a == 255) continue;
        if (a == 0) {
            p[0] = p[1] = p[2] = 0;
            continue;
        }
        p[0] = (uint8_t)(((uint32_t)p[0] * a + 127u) / 255u);
        p[1] = (uint8_t)(((uint32_t)p[1] * a + 127u) / 255u);
        p[2] = (uint8_t)(((uint32_t)p[2] * a + 127u) / 255u);
    }
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
    size_t sz = img_storage_size(&st->images[idx]);
    if (sz <= st->total_bytes)
        st->total_bytes -= sz;
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
    int rel = p->relative;
    int live = !virt && !rel && p->pin.y >= 0;
    unref_image(st, p->image_id);
    int32_t n = pl_count(st) - 1;
    if (idx < n) st->pl[idx] = st->pl[n];
    memset(&st->pl[n], 0, sizeof(jt_img_placement));
    if (virt) st->virtual_n--;
    else if (rel) st->relative_n--;
    else if (live) st->live_n--;
    else st->hist_n--;
    st->dirty = 1;
}

static const jt_img_placement *find_pl_key(
    const jt_img_store *st,
    uint32_t image_id,
    uint32_t pid,
    int internal
) {
    if (!st || image_id == 0 || pid == 0) return NULL;
    int32_t n = pl_count(st);
    for (int32_t i = 0; i < n; i++) {
        const jt_img_placement *p = &st->pl[i];
        if (p->image_id == image_id && p->placement_id == pid
            && (int)p->internal == internal)
            return p;
    }
    return NULL;
}

static const jt_img_placement *find_pl_external(
    const jt_img_store *st,
    uint32_t image_id,
    uint32_t pid
) {
    if (!st || image_id == 0 || pid == 0) return NULL;
    int32_t n = pl_count(st);
    for (int32_t i = 0; i < n; i++) {
        const jt_img_placement *p = &st->pl[i];
        if (p->image_id == image_id && !p->internal && p->placement_id == pid)
            return p;
    }
    return NULL;
}

static const jt_img_placement *preferred_pl(const jt_img_store *st, uint32_t image_id) {
    const jt_img_placement *best = NULL;
    if (!st || image_id == 0) return NULL;
    int32_t n = pl_count(st);
    for (int32_t i = 0; i < n; i++) {
        const jt_img_placement *p = &st->pl[i];
        if (p->image_id != image_id) continue;
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

static int keys_equal(
    uint32_t a_img,
    uint32_t a_pid,
    int a_internal,
    const jt_img_placement *b
) {
    if (!b) return 0;
    if (a_img != b->image_id || a_pid != b->placement_id) return 0;
    if (a_internal != b->internal) return 0;
    return 1;
}

static int resolve_parent(
    const jt_img_store *st,
    uint32_t child_id,
    uint32_t child_pid,
    int child_internal,
    uint32_t parent_image_id,
    uint32_t parent_pid,
    const jt_img_placement **out
) {
    if (!jt_img_find((jt_img_store *)st, parent_image_id))
        return JT_IMG_ENOPARENT_IMG;
    const jt_img_placement *parent = parent_pid
        ? find_pl_external(st, parent_image_id, parent_pid)
        : preferred_pl(st, parent_image_id);
    if (!parent) return JT_IMG_ENOPARENT_PL;
    if (!child_internal && child_pid
        && keys_equal(child_id, child_pid, 0, parent))
        return JT_IMG_ESELF;
    int depth = 1;
    const jt_img_placement *cur = parent;
    for (;;) {
        if (!child_internal && child_pid
            && keys_equal(child_id, child_pid, 0, cur))
            return JT_IMG_ECYCLE;
        if (!cur->relative) break;
        if (depth >= JT_IMG_PARENT_CHAIN) return JT_IMG_ETOODEEP;
        depth++;
        cur = find_pl_key(
            st, cur->parent_image_id, cur->parent_placement_id, cur->parent_internal
        );
        if (!cur) return JT_IMG_ENOPARENT_PL;
    }
    *out = parent;
    return 0;
}

static void remove_orphans(jt_img_store *st) {
    int removed = 1;
    while (removed) {
        removed = 0;
        int32_t n = pl_count(st);
        for (int32_t i = n - 1; i >= 0; i--) {
            if (!st->pl[i].relative) continue;
            if (find_pl_key(
                    st,
                    st->pl[i].parent_image_id,
                    st->pl[i].parent_placement_id,
                    st->pl[i].parent_internal
                ))
                continue;
            remove_placement_at(st, i);
            removed = 1;
        }
    }
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

static int32_t pick_evict(const jt_img_store *st, uint32_t keep_id) {
    int32_t best = -1;
    uint8_t pri = 255;
    uint64_t gen = UINT64_MAX;
    uint32_t id = UINT32_MAX;
    for (int32_t i = 0; i < st->image_n; i++) {
        const jt_img *im = &st->images[i];
        if (keep_id && im->id == keep_id) continue;
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

static int evict_for_except(jt_img_store *st, size_t need, uint32_t keep_id) {
    if (!st) return 0;
    if (need > JT_IMG_QUOTA) return 0;
    int guard = JT_IMG_MAX_IMAGES + 2;
    while (guard-- > 0) {
        if (st->total_bytes + need <= JT_IMG_QUOTA && st->image_n < JT_IMG_MAX_IMAGES) return 1;
        int32_t idx = pick_evict(st, keep_id);
        if (idx < 0) return 0;
        uint32_t id = st->images[idx].id;
        int32_t n = pl_count(st);
        for (int32_t i = n - 1; i >= 0; i--) {
            if (st->pl[i].image_id == id) remove_placement_at(st, i);
        }
        jt_img *im = jt_img_find(st, id);
        if (im) remove_image_at(st, (int32_t)(im - st->images));
        remove_orphans(st);
    }
    return st->total_bytes + need <= JT_IMG_QUOTA && st->image_n < JT_IMG_MAX_IMAGES;
}

static int evict_for(jt_img_store *st, size_t need) {
    return evict_for_except(st, need, 0);
}

static int evict_bytes(jt_img_store *st, size_t need, uint32_t keep_id) {
    if (!st) return 0;
    if (need > JT_IMG_QUOTA) return 0;
    int guard = JT_IMG_MAX_IMAGES + 2;
    while (guard-- > 0) {
        if (st->total_bytes + need <= JT_IMG_QUOTA) return 1;
        int32_t idx = pick_evict(st, keep_id);
        if (idx < 0) return 0;
        uint32_t id = st->images[idx].id;
        int32_t n = pl_count(st);
        for (int32_t i = n - 1; i >= 0; i--) {
            if (st->pl[i].image_id == id) remove_placement_at(st, i);
        }
        jt_img *im = jt_img_find(st, id);
        if (im) remove_image_at(st, (int32_t)(im - st->images));
        remove_orphans(st);
    }
    return st->total_bytes + need <= JT_IMG_QUOTA;
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
    remove_orphans(st);
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
        return JT_IMG_ENOSPC;
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
        return JT_IMG_ENOSPC;
    }
    if (st->image_n >= JT_IMG_MAX_IMAGES) {
        free(rgba);
        return JT_IMG_ENOSPC;
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
        return JT_IMG_ENOSPC;
    }

    if (ld->unicode && ld->parent_id) return JT_IMG_EVIRTUAL_REL;

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
    }

    const jt_img_placement *parent = NULL;
    uint32_t parent_image_id = 0, parent_placement_id = 0;
    uint8_t parent_internal = 0;
    if (!ld->unicode && ld->parent_id) {
        int prc = resolve_parent(
            st, id, pid, internal,
            ld->parent_id, ld->parent_placement_id, &parent
        );
        if (prc != 0) return prc;
        parent_image_id = parent->image_id;
        parent_placement_id = parent->placement_id;
        parent_internal = parent->internal;
    }

    if (!internal) {
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

    if (ld->parent_id) {
        if (!parent_image_id) return JT_IMG_ENOPARENT_PL;
        jt_img_placement *p = &st->pl[pl_count(st)];
        memset(p, 0, sizeof *p);
        p->image_id = id;
        p->placement_id = pid;
        p->internal = internal;
        p->relative = 1;
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
        p->parent_image_id = parent_image_id;
        p->parent_placement_id = parent_placement_id;
        p->parent_internal = parent_internal;
        p->rel_h = ld->rel_h;
        p->rel_v = ld->rel_v;
        st->relative_n++;
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

int jt_img_anim_add_frame(
    jt_scr *s,
    const jt_img_loading *ld,
    uint8_t *rgba,
    uint32_t w,
    uint32_t h,
    uint32_t *out_frame
) {
    if (out_frame) *out_frame = ld ? ld->anim_edit_frame : 0;
    if (!s || !ld || !rgba) {
        free(rgba);
        return JT_IMG_EINVAL;
    }
    jt_img_store *st = jt_img_active(s);
    if (!st) {
        free(rgba);
        return JT_IMG_ENOENT;
    }
    uint32_t id = ld->image_id;
    if (id == 0 && ld->number) {
        jt_img *by = jt_img_find_number(st, ld->number);
        if (by) id = by->id;
    }
    jt_img *im = jt_img_find(st, id);
    if (!im) {
        free(rgba);
        return JT_IMG_ENOENT;
    }
    if (ld->anim_image_gen && im->generation != ld->anim_image_gen) {
        free(rgba);
        return JT_IMG_ENOENT;
    }
    if (!im->rgba) {
        free(rgba);
        return JT_IMG_EINVAL_INCOMPLETE;
    }
    if (w > im->width || h > im->height) {
        free(rgba);
        return JT_IMG_EINVAL_DIM;
    }
    uint32_t count = img_frame_count(im);
    uint32_t r = ld->anim_edit_frame;
    uint32_t number = (r == 0 || r > count + 1) ? count + 1 : r;
    if (out_frame) *out_frame = number;
    im->has_anim = 1;

    if (number == count + 1) {
        if (im->frame_n >= JT_IMG_MAX_FRAMES) {
            free(rgba);
            return JT_IMG_ENOSPC;
        }
        uint32_t gap;
        if (ld->anim_gap_ms > 0) gap = (uint32_t)ld->anim_gap_ms;
        else if (ld->anim_gap_ms < 0) gap = 0;
        else gap = JT_IMG_DEFAULT_GAP_MS;
        if (ld->anim_create_frame > 0
            && !img_frame_ptr(im, ld->anim_create_frame)) {
            free(rgba);
            return JT_IMG_EINVAL_BASE;
        }
        size_t frame_len = (size_t)im->width * (size_t)im->height * 4;
        if (!evict_bytes(st, frame_len, id)) {
            free(rgba);
            return JT_IMG_ENOSPC;
        }
        im = jt_img_find(st, id);
        if (!im || !im->rgba) {
            free(rgba);
            return JT_IMG_ENOENT;
        }
        uint8_t *canvas = (uint8_t *)malloc(frame_len);
        if (!canvas) {
            free(rgba);
            return JT_IMG_ENOSPC;
        }
        if (ld->anim_create_frame > 0) {
            uint8_t *base = img_frame_ptr(im, ld->anim_create_frame);
            if (!base) {
                free(canvas);
                free(rgba);
                return JT_IMG_EINVAL_BASE;
            }
            memcpy(canvas, base, frame_len);
        } else {
            fill_bg(canvas, frame_len, ld->anim_bg);
        }
        compose_rect(
            canvas, im->width, im->height,
            rgba, w, h,
            ld->anim_x, ld->anim_y,
            ld->anim_overwrite
        );
        jt_img_frame *nf = (jt_img_frame *)realloc(
            im->frames, (size_t)(im->frame_n + 1) * sizeof(jt_img_frame)
        );
        if (!nf) {
            free(canvas);
            free(rgba);
            return JT_IMG_ENOSPC;
        }
        im->frames = nf;
        im->frames[im->frame_n].rgba = canvas;
        im->frames[im->frame_n].gap_ms = gap;
        im->frame_n++;
        st->total_bytes += frame_len;
        st->generation++;
        st->dirty = 1;
        free(rgba);
        return 0;
    }

    uint8_t *dst = img_frame_ptr(im, number);
    if (!dst) {
        free(rgba);
        return JT_IMG_ENOENT;
    }
    if (ld->anim_gap_ms != 0) {
        set_gap_at(
            im, number - 1,
            ld->anim_gap_ms > 0 ? (uint32_t)ld->anim_gap_ms : 0
        );
    }
    compose_rect(
        dst, im->width, im->height,
        rgba, w, h,
        ld->anim_x, ld->anim_y,
        ld->anim_overwrite
    );
    if (number - 1 == im->current_index) {
        im->frame_shown_at_ms = 0;
        mark_img_content(st, im);
    } else {
        st->generation++;
        st->dirty = 1;
    }
    free(rgba);
    return 0;
}

int jt_img_anim_control(jt_scr *s, const jt_img_loading *ld) {
    if (!s || !ld) return JT_IMG_EINVAL;
    if (ld->image_id == 0 && ld->number == 0) return JT_IMG_EINVAL;
    jt_img_store *st = jt_img_active(s);
    if (!st) return JT_IMG_ENOENT;
    jt_img *im = ld->image_id
        ? jt_img_find(st, ld->image_id)
        : jt_img_find_number(st, ld->number);
    if (!im) return JT_IMG_ENOENT;
    im->has_anim = 1;
    uint32_t count = img_frame_count(im);
    if (ld->anim_edit_frame != 0 && ld->anim_edit_frame <= count
        && ld->anim_gap_ms != 0) {
        set_gap_at(
            im, ld->anim_edit_frame - 1,
            ld->anim_gap_ms > 0 ? (uint32_t)ld->anim_gap_ms : 0
        );
        st->generation++;
        st->dirty = 1;
    }
    if (ld->anim_current != 0 && ld->anim_current <= count
        && ld->anim_current - 1 != im->current_index) {
        im->current_index = ld->anim_current - 1;
        im->frame_shown_at_ms = 0;
        mark_img_content(st, im);
    }
    if (ld->anim_action == 1 || ld->anim_action == 2 || ld->anim_action == 3) {
        uint8_t old = im->anim_state;
        im->anim_state = ld->anim_action == 1
            ? JT_IMG_ANIM_STOPPED
            : (ld->anim_action == 2 ? JT_IMG_ANIM_LOADING : JT_IMG_ANIM_RUNNING);
        if (old == JT_IMG_ANIM_STOPPED && im->anim_state != JT_IMG_ANIM_STOPPED)
            im->frame_shown_at_ms = 0;
        im->current_loop = 0;
        st->generation++;
        st->dirty = 1;
    }
    if (ld->anim_loops != 0) {
        im->max_loops = ld->anim_loops - 1;
        st->generation++;
        st->dirty = 1;
    }
    return 0;
}

int jt_img_anim_compose(jt_scr *s, const jt_img_loading *ld) {
    if (!s || !ld) return JT_IMG_EINVAL;
    if (ld->image_id == 0 && ld->number == 0) return JT_IMG_EINVAL;
    jt_img_store *st = jt_img_active(s);
    if (!st) return JT_IMG_ENOENT;
    jt_img *im = ld->image_id
        ? jt_img_find(st, ld->image_id)
        : jt_img_find_number(st, ld->number);
    if (!im) return JT_IMG_ENOENT;
    if (!im->rgba) return JT_IMG_EINVAL_INCOMPLETE;
    uint8_t *src = img_frame_ptr(im, ld->anim_src_frame);
    if (!src) return JT_IMG_ENOENT_SRC;
    uint8_t *dst = img_frame_ptr(im, ld->anim_dst_frame);
    if (!dst) return JT_IMG_ENOENT_DST;
    uint64_t width = ld->anim_w ? ld->anim_w : im->width;
    uint64_t height = ld->anim_h ? ld->anim_h : im->height;
    if ((uint64_t)ld->anim_x + width > im->width
        || (uint64_t)ld->anim_y + height > im->height)
        return JT_IMG_EINVAL_BOUNDS;
    if ((uint64_t)ld->anim_src_x + width > im->width
        || (uint64_t)ld->anim_src_y + height > im->height)
        return JT_IMG_EINVAL_BOUNDS;
    if (ld->anim_src_frame == ld->anim_dst_frame) {
        uint32_t x0 = ld->anim_src_x > ld->anim_x ? ld->anim_src_x : ld->anim_x;
        uint32_t x1min = ld->anim_src_x < ld->anim_x ? ld->anim_src_x : ld->anim_x;
        uint32_t y0 = ld->anim_src_y > ld->anim_y ? ld->anim_src_y : ld->anim_y;
        uint32_t y1min = ld->anim_src_y < ld->anim_y ? ld->anim_src_y : ld->anim_y;
        int x_over = x0 < x1min + (uint32_t)width;
        int y_over = y0 < y1min + (uint32_t)height;
        if (x_over && y_over) return JT_IMG_EINVAL_OVERLAP;
    }
    compose_canvas_rect(
        dst, src, im->width,
        (uint32_t)width, (uint32_t)height,
        ld->anim_src_x, ld->anim_src_y,
        ld->anim_x, ld->anim_y,
        ld->anim_overwrite
    );
    uint32_t current = im->has_anim ? im->current_index : 0;
    if (ld->anim_dst_frame > 0 && ld->anim_dst_frame - 1 == current)
        mark_img_content(st, im);
    else {
        st->generation++;
        st->dirty = 1;
    }
    return 0;
}

int jt_img_anim_delete_frame(
    jt_scr *s,
    uint32_t i,
    uint32_t I,
    uint32_t frame,
    int upper
) {
    if (!s) return JT_IMG_EINVAL;
    if (i == 0 && I == 0) return JT_IMG_EINVAL;
    jt_img_store *st = jt_img_active(s);
    if (!st) return JT_IMG_ENOENT;
    jt_img *im = i ? jt_img_find(st, i) : jt_img_find_number(st, I);
    if (!im) return JT_IMG_ENOENT;
    if (!im->has_anim || im->frame_n == 0) {
        if (!upper) return 0;
        uint32_t id = im->id;
        int32_t n = pl_count(st);
        for (int32_t k = n - 1; k >= 0; k--) {
            if (st->pl[k].image_id == id) remove_placement_at(st, k);
        }
        im = jt_img_find(st, id);
        if (im) remove_image_at(st, (int32_t)(im - st->images));
        remove_orphans(st);
        jt_img_sync_live(s);
        return 0;
    }
    uint32_t count = img_frame_count(im);
    uint32_t number = frame < count ? frame : count;
    if (number == 0) number = 1;
    size_t one = (size_t)im->width * (size_t)im->height * 4;
    if (number == 1) {
        if (one <= st->total_bytes) st->total_bytes -= one;
        else st->total_bytes = 0;
        free(im->rgba);
        jt_img_frame promoted = im->frames[0];
        if (im->frame_n > 1)
            memmove(&im->frames[0], &im->frames[1],
                    (size_t)(im->frame_n - 1) * sizeof(jt_img_frame));
        im->frame_n--;
        if (im->frame_n == 0) {
            free(im->frames);
            im->frames = NULL;
        } else {
            jt_img_frame *nf = (jt_img_frame *)realloc(
                im->frames, (size_t)im->frame_n * sizeof(jt_img_frame)
            );
            if (nf) im->frames = nf;
        }
        im->rgba = promoted.rgba;
        im->nbytes = one;
        im->root_gap_ms = promoted.gap_ms;
    } else {
        int32_t idx = (int32_t)number - 2;
        if (one <= st->total_bytes) st->total_bytes -= one;
        else st->total_bytes = 0;
        free(im->frames[idx].rgba);
        if (idx < im->frame_n - 1)
            memmove(&im->frames[idx], &im->frames[idx + 1],
                    (size_t)(im->frame_n - 1 - idx) * sizeof(jt_img_frame));
        im->frame_n--;
        if (im->frame_n == 0) {
            free(im->frames);
            im->frames = NULL;
        } else {
            jt_img_frame *nf = (jt_img_frame *)realloc(
                im->frames, (size_t)im->frame_n * sizeof(jt_img_frame)
            );
            if (nf) im->frames = nf;
        }
    }
    uint32_t removed_idx = number == 1 ? 0 : number - 2;
    uint32_t remaining = (uint32_t)im->frame_n;
    if (im->current_index > remaining) {
        im->current_index = remaining;
        im->frame_shown_at_ms = 0;
        mark_img_content(st, im);
    } else if (removed_idx == im->current_index) {
        im->frame_shown_at_ms = 0;
        mark_img_content(st, im);
    } else {
        if (removed_idx < im->current_index) im->current_index--;
        st->generation++;
        st->dirty = 1;
    }
    return 0;
}

int64_t jt_img_anim_tick(jt_scr *s, uint64_t now_ms) {
    if (!s) return -1;
    jt_img_store *st = jt_img_active(s);
    if (!st || st->image_n == 0) return -1;
    int64_t min_delay = -1;
    for (int32_t i = 0; i < st->image_n; i++) {
        jt_img *im = &st->images[i];
        if (!im->has_anim) continue;
        if (im->anim_state == JT_IMG_ANIM_STOPPED) continue;
        if (im->frame_n == 0) continue;
        if (im->placement_n == 0) continue;
        if (!im->rgba) continue;
        if (anim_duration_ms(im) == 0) continue;
        if (im->max_loops > 0 && im->current_loop >= im->max_loops) continue;

        uint64_t shown_at;
        if (im->frame_shown_at_ms == 0 || im->frame_shown_at_ms > now_ms)
            shown_at = now_ms;
        else
            shown_at = im->frame_shown_at_ms;
        im->frame_shown_at_ms = shown_at;

        uint64_t next_at = add_sat_u64(shown_at, gap_at(im, im->current_index));
        if (now_ms >= next_at) {
            uint32_t count = img_frame_count(im);
            uint32_t idx = im->current_index;
            int parked = 0;
            for (;;) {
                uint32_t next = (idx + 1) % count;
                if (next == 0) {
                    if (im->anim_state == JT_IMG_ANIM_LOADING) {
                        parked = 1;
                        break;
                    }
                    im->current_loop++;
                    if (im->max_loops > 0 && im->current_loop >= im->max_loops) {
                        parked = 1;
                        break;
                    }
                }
                idx = next;
                if (gap_at(im, idx) != 0) break;
            }
            if (!parked) {
                im->current_index = idx;
                im->frame_shown_at_ms = now_ms;
                mark_img_content(st, im);
                next_at = add_sat_u64(now_ms, gap_at(im, idx));
            }
        }
        if (next_at > now_ms) {
            uint64_t delay = next_at - now_ms;
            if (min_delay < 0 || delay < (uint64_t)min_delay)
                min_delay = (int64_t)delay;
        }
    }
    return min_delay;
}

uint32_t jt_img_anim_frame_count(const jt_scr *s, uint32_t id) {
    if (!s || id == 0) return 0;
    const jt_img_store *st = s->in_alt ? s->img_alt : s->img_primary;
    if (!st) return 0;
    for (int32_t i = 0; i < st->image_n; i++) {
        if (st->images[i].id == id) return img_frame_count(&st->images[i]);
    }
    return 0;
}

uint32_t jt_img_anim_current(const jt_scr *s, uint32_t id) {
    if (!s || id == 0) return 0;
    const jt_img_store *st = s->in_alt ? s->img_alt : s->img_primary;
    if (!st) return 0;
    for (int32_t i = 0; i < st->image_n; i++) {
        if (st->images[i].id == id) return st->images[i].current_index + 1;
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
    uint8_t kind = d;
    if (kind >= 'A' && kind <= 'Z') kind = (uint8_t)(kind - 'A' + 'a');
    /* Virtuals: identity deletes only. Relatives: identity plus z. */
    if (p->virtual) {
        if (kind != 'i' && kind != 'n' && kind != 'r') return 0;
    } else if (p->relative) {
        if (kind != 'i' && kind != 'n' && kind != 'r' && kind != 'z') return 0;
    }
    int32_t x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    if (!p->virtual && !p->relative)
        dest_cell_rect(p, s, &x0, &y0, &x1, &y1);
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
    remove_orphans(st);
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
        if (!st->pl[i].virtual && !st->pl[i].relative && st->pl[i].pin.y < 0)
            remove_placement_at(st, i);
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
        if (!st->pl[i].virtual && !st->pl[i].relative && st->pl[i].pin.y < 0
            && st->pl[i].pin.doc < lo)
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
            if (p->virtual || p->relative || p->pin.y < 0) continue;
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
        if (p->virtual || p->relative || p->pin.y < 0) continue;
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
            if (p->virtual || p->relative) continue;
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

static uint64_t view_start_doc(const jt_scr *s, int32_t integer_row) {
    if (s->in_alt) return s->lines_scrolled;
    uint64_t lo = 0;
    if (s->lines_scrolled >= (uint64_t)s->sb_len)
        lo = s->lines_scrolled - (uint64_t)s->sb_len;
    return lo + (uint64_t)(integer_row < 0 ? 0 : integer_row);
}

static int placement_to_snap(
    const jt_img_placement *p,
    const jt_img *im,
    int32_t origin_x,
    int32_t paint_row,
    uint32_t cell_w,
    uint32_t cell_h,
    int32_t vw,
    int32_t vh,
    jt_img_snap *o
) {
    uint32_t off_x = p->off_x;
    uint32_t off_y = p->off_y;
    if (off_x >= cell_w) off_x = cell_w ? cell_w - 1 : 0;
    if (off_y >= cell_h) off_y = cell_h ? cell_h - 1 : 0;
    int32_t ox0 = origin_x * (int32_t)cell_w + (int32_t)off_x;
    int32_t oy0 = paint_row * (int32_t)cell_h + (int32_t)off_y;
    int32_t sx0, sy0;
    if (p->pixel_size) {
        sx0 = (int32_t)p->src_w;
        sy0 = (int32_t)p->src_h;
    } else {
        sx0 = (int32_t)p->cols * (int32_t)cell_w - (int32_t)off_x;
        sy0 = (int32_t)p->rows * (int32_t)cell_h - (int32_t)off_y;
    }
    if (sx0 <= 0 || sy0 <= 0) return 0;
    int32_t ix0 = ox0 > 0 ? ox0 : 0;
    int32_t iy0 = oy0 > 0 ? oy0 : 0;
    int32_t ix1 = ox0 + sx0 < vw ? ox0 + sx0 : vw;
    int32_t iy1 = oy0 + sy0 < vh ? oy0 + sy0 : vh;
    if (ix1 <= ix0 || iy1 <= iy0) return 0;
    double u0 = (double)p->src_x + (double)(ix0 - ox0) * (double)p->src_w / (double)sx0;
    double v0 = (double)p->src_y + (double)(iy0 - oy0) * (double)p->src_h / (double)sy0;
    double u1 = (double)p->src_x + (double)(ix1 - ox0) * (double)p->src_w / (double)sx0;
    double v1 = (double)p->src_y + (double)(iy1 - oy0) * (double)p->src_h / (double)sy0;
    if (u0 < 0) u0 = 0;
    if (v0 < 0) v0 = 0;
    if (u1 > (double)im->width) u1 = (double)im->width;
    if (v1 > (double)im->height) v1 = (double)im->height;
    o->image_id = im->id;
    o->generation = im->generation;
    o->z = p->z;
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
    o->rgba = img_display_rgba(im);
    return 1;
}

static const jt_img *img_by_id(const jt_img_store *st, uint32_t id) {
    for (int32_t k = 0; k < st->image_n; k++) {
        if (st->images[k].id == id) return &st->images[k];
    }
    return NULL;
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
    uint64_t vsd = view_start_doc(s, integer_row);
    int32_t vw = s->cols * (int32_t)cell_w;
    int32_t vh = paint_rows * (int32_t)cell_h;
    int32_t n = 0;
    for (int32_t i = 0; i < npl; i++) {
        const jt_img_placement *p = &st->pl[i];
        if (p->virtual || p->relative) continue;
        const jt_img *im = img_by_id(st, p->image_id);
        if (!im || !im->rgba) continue;
        uint64_t origin_doc = p->pin.y >= 0
            ? s->lines_scrolled + (uint64_t)p->pin.y
            : p->pin.doc;
        int32_t paint_row = (int32_t)((int64_t)origin_doc - (int64_t)vsd);
        if (n >= cap) {
            static int once;
            if (!once) {
                once = 1;
                fputs("jetty: kitty-graphics: snapshot-cap\n", stderr);
            }
            break;
        }
        if (placement_to_snap(p, im, p->pin.x, paint_row, cell_w, cell_h, vw, vh, &out[n]))
            n++;
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
    o->rgba = img_display_rgba(im);
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

static int resolve_chain(
    const jt_img_store *st,
    const jt_img_placement *rel,
    const jt_img_placement **root,
    int32_t *h,
    int32_t *v
) {
    int32_t acc_h = rel->rel_h;
    int32_t acc_v = rel->rel_v;
    const jt_img_placement *cur = rel;
    int depth = 1;
    while (cur->relative) {
        if (depth >= JT_IMG_PARENT_CHAIN) return 0;
        const jt_img_placement *par = find_pl_key(
            st, cur->parent_image_id, cur->parent_placement_id, cur->parent_internal
        );
        if (!par) return 0;
        if (par->relative) {
            acc_h += par->rel_h;
            acc_v += par->rel_v;
        }
        cur = par;
        depth++;
    }
    *root = cur;
    *h = acc_h;
    *v = acc_v;
    return 1;
}

static int virt_origin_cell(
    const jt_scr *s,
    const jt_img_store *st,
    const Cell *paint,
    int32_t cols,
    int32_t paint_rows,
    const jt_img_placement *root,
    int32_t *ox,
    int32_t *oy
) {
    /* Kitty/Ghostty: min x and min y of matching cells, independently. */
    if (!paint || cols <= 0 || paint_rows <= 0) return 0;
    int found = 0;
    int32_t min_x = 0, min_y = 0;
    for (int32_t y = 0; y < paint_rows; y++) {
        for (int32_t x = 0; x < cols; x++) {
            ph_run cur;
            if (!parse_placeholder(s, &paint[y * cols + x], &cur)) continue;
            uint32_t image_id = cur.image_id_low;
            if (cur.has_high) image_id |= ((uint32_t)cur.image_id_high) << 24;
            if (image_id == 0) continue;
            uint32_t pid = cur.has_pid ? cur.placement_id : 0;
            const jt_img_placement *t = placeholder_target(st, image_id, pid);
            if (!t) continue;
            if (t->image_id != root->image_id || t->placement_id != root->placement_id)
                continue;
            if (!found || x < min_x) min_x = x;
            if (!found || y < min_y) min_y = y;
            found = 1;
        }
    }
    if (!found) return 0;
    *ox = min_x;
    *oy = min_y;
    return 1;
}

int32_t jt_img_relative_scan(
    const jt_scr *s,
    const Cell *paint,
    int32_t cols,
    int32_t paint_rows,
    int32_t integer_row,
    uint32_t cell_w,
    uint32_t cell_h,
    jt_img_snap *out,
    int32_t cap
) {
    if (!s || !out || cap <= 0 || paint_rows <= 0) return 0;
    const jt_img_store *st = s->in_alt ? s->img_alt : s->img_primary;
    if (!st || st->relative_n == 0) return 0;
    if (cell_w == 0) cell_w = 1;
    if (cell_h == 0) cell_h = 1;
    uint64_t vsd = view_start_doc(s, integer_row);
    int32_t vw = s->cols * (int32_t)cell_w;
    int32_t vh = paint_rows * (int32_t)cell_h;
    int32_t n = 0;
    int32_t npl = pl_count(st);
    for (int32_t i = 0; i < npl; i++) {
        const jt_img_placement *p = &st->pl[i];
        if (!p->relative) continue;
        const jt_img *im = img_by_id(st, p->image_id);
        if (!im || !im->rgba) continue;
        const jt_img_placement *root = NULL;
        int32_t h = 0, v = 0;
        if (!resolve_chain(st, p, &root, &h, &v)) continue;
        int32_t ox, oy;
        if (root->virtual) {
            if (!virt_origin_cell(s, st, paint, cols, paint_rows, root, &ox, &oy))
                continue;
            ox += h;
            oy += v;
        } else {
            uint64_t origin_doc = root->pin.y >= 0
                ? s->lines_scrolled + (uint64_t)root->pin.y
                : root->pin.doc;
            ox = root->pin.x + h;
            oy = (int32_t)((int64_t)origin_doc - (int64_t)vsd) + v;
        }
        if (n >= cap) break;
        if (placement_to_snap(p, im, ox, oy, cell_w, cell_h, vw, vh, &out[n]))
            n++;
    }
    return n;
}
