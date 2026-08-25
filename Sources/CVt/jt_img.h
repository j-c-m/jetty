#ifndef JT_IMG_H
#define JT_IMG_H

#include "jt_cell.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct jt_scr;
struct jt_vt_host;

enum { JT_IMG_MAX_DIM = 10000 };
enum { JT_IMG_MAX_BYTES = 400u * 1024u * 1024u };
enum { JT_IMG_QUOTA = 320u * 1000u * 1000u };
enum { JT_IMG_MAX_IMAGES = 256 };
enum { JT_IMG_MAX_PLACEMENTS = 1024 };
enum { JT_IMG_MAX_APC = 65536 };
enum { JT_IMG_PARENT_CHAIN = 8 };

enum {
    JT_IMG_OK = 0,
    JT_IMG_ENOENT = -1,
    JT_IMG_EINVAL = -2,
    JT_IMG_ENOSPC = -3,
    JT_IMG_ENOPARENT_IMG = -4,
    JT_IMG_ENOPARENT_PL = -5,
    JT_IMG_ESELF = -6,
    JT_IMG_ECYCLE = -7,
    JT_IMG_ETOODEEP = -8,
    JT_IMG_EVIRTUAL_REL = -9
};

typedef struct jt_img_pin {
    int32_t x;
    int32_t y;
    uint64_t doc;
} jt_img_pin;

typedef struct jt_img_placement {
    uint32_t image_id;
    uint32_t placement_id;
    uint8_t internal;
    uint8_t virtual;
    uint8_t relative;
    uint8_t pixel_size;
    int32_t z;
    uint32_t src_x, src_y, src_w, src_h;
    uint32_t cols, rows;
    uint32_t off_x, off_y;
    uint32_t parent_image_id, parent_placement_id;
    uint8_t parent_internal;
    int32_t rel_h, rel_v;
    jt_img_pin pin;
} jt_img_placement;

typedef struct jt_img {
    uint32_t id, number;
    uint32_t width, height;
    uint8_t *rgba;
    size_t nbytes;
    uint32_t placement_n;
    uint8_t transient;
    uint64_t generation;
} jt_img;

typedef struct jt_img_store {
    jt_img images[JT_IMG_MAX_IMAGES];
    int32_t image_n;
    jt_img_placement pl[JT_IMG_MAX_PLACEMENTS];
    int32_t live_n;
    int32_t hist_n;
    int32_t virtual_n;
    int32_t relative_n;
    size_t total_bytes;
    uint64_t generation;
    uint32_t dirty;
    uint32_t next_internal_pid;
    uint32_t next_auto_id;
} jt_img_store;

typedef struct jt_img_loading {
    uint8_t active;
    uint8_t more;
    uint8_t action;
    uint8_t quiet;
    uint8_t format;
    uint8_t medium;
    uint8_t compress;
    uint8_t no_cursor;
    uint8_t unicode;
    uint8_t transient;
    uint8_t has_display;
    uint32_t w, h, S, O;
    uint32_t image_id, number, placement_id;
    uint32_t parent_id, parent_placement_id;
    int32_t rel_h, rel_v;
    int32_t z;
    uint32_t src_x, src_y, src_w, src_h;
    uint32_t cols, rows, off_x, off_y;
    uint8_t *data;
    size_t n, cap;
    uint32_t generation;
} jt_img_loading;

typedef struct jt_img_snap {
    uint32_t image_id;
    uint64_t generation;
    int32_t z;
    int32_t ox, oy, sx, sy;
    uint16_t u0, v0, u1, v1;
    uint32_t width, height;
    const uint8_t *rgba;
} jt_img_snap;

void jt_img_store_init(jt_img_store *st);
void jt_img_store_reset(jt_img_store *st);
void jt_img_store_deinit(jt_img_store *st);

void jt_img_abort_loading(jt_img_loading *ld);

jt_img_store *jt_img_active(struct jt_scr *s);
void jt_img_sync_live(struct jt_scr *s);

void jt_img_shift_region(struct jt_scr *s, int32_t top, int32_t bot, int dir, int sb_pushed);
void jt_img_clear_visible(struct jt_scr *s);
void jt_img_clear_history_pins(struct jt_scr *s);
void jt_img_on_resize(struct jt_scr *s, int32_t old_cols, int32_t old_rows, int32_t nc, int32_t nr);

int32_t jt_img_live_n(const struct jt_scr *s);
int32_t jt_img_hist_n(const struct jt_scr *s);
int32_t jt_img_virtual_n(const struct jt_scr *s);
int32_t jt_img_relative_n(const struct jt_scr *s);

int32_t jt_img_relative_scan(
    const struct jt_scr *s,
    const Cell *paint,
    int32_t cols,
    int32_t paint_rows,
    int32_t integer_row,
    uint32_t cell_w,
    uint32_t cell_h,
    jt_img_snap *out,
    int32_t cap
);

int32_t jt_img_placeholder_scan(
    const struct jt_scr *s,
    const Cell *paint,
    int32_t cols,
    int32_t paint_rows,
    uint32_t cell_w,
    uint32_t cell_h,
    uint8_t *hide,
    jt_img_snap *out,
    int32_t cap
);
void jt_img_sort_snaps(jt_img_snap *out, int32_t n);

int32_t jt_img_snapshot(
    const struct jt_scr *s,
    int32_t integer_row,
    int32_t paint_rows,
    uint32_t cell_w,
    uint32_t cell_h,
    jt_img_snap *out,
    int32_t cap
);

void jt_scr_set_cell_px(struct jt_scr *s, uint32_t w, uint32_t h);
void jt_scr_set_kitty_graphics(struct jt_scr *s, int on);

uint32_t jt_img_alloc_id(jt_img_store *st);
jt_img *jt_img_find(jt_img_store *st, uint32_t id);
jt_img *jt_img_find_number(jt_img_store *st, uint32_t number);
int jt_img_add(
    struct jt_scr *s,
    uint32_t *id,
    uint32_t number,
    uint8_t *rgba,
    uint32_t w,
    uint32_t h,
    uint8_t transient
);
int jt_img_put(struct jt_scr *s, const jt_img_loading *ld);
int jt_img_delete(
    struct jt_scr *s,
    uint8_t d,
    uint32_t i,
    uint32_t I,
    uint32_t p,
    uint32_t x,
    uint32_t y,
    int32_t z
);
void jt_img_drop_id(struct jt_scr *s, uint32_t id);
uint8_t *jt_img_rgb_to_rgba(const uint8_t *rgb, uint32_t w, uint32_t h);

#ifdef __cplusplus
}
#endif

#endif
