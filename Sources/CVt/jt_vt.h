#ifndef JT_VT_H
#define JT_VT_H

#include "jt_cell.h"
#include "jt_version.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct jt_pen {
    uint32_t fg, bg, ul_color;
    uint16_t attrs, extra;
} jt_pen;

typedef struct jt_saved {
    int32_t x, y, pending_wrap;
    uint32_t fg, bg, ul_color;
    uint16_t attrs, extra;
    int32_t g0, g1, gl;
    int32_t valid;
} jt_saved;

typedef struct jt_buf {
    Cell *grid;
    int32_t *rowmap;
    int32_t grid_rows;
    int32_t cx, cy, pending_wrap;
    int32_t scroll_top, scroll_bottom;
    uint8_t *tabstops;
    uint8_t *dirty;
    uint8_t *wrap;
    uint8_t *erased;
    Cell *erase; /* BCE prototype per physical row while erased[py] */
} jt_buf;

typedef struct jt_scr {
    jt_buf primary, alt;
    jt_buf *active;
    int32_t cols, rows;
    int32_t in_alt;
    int32_t auto_wrap, insert_mode, origin_mode;
    int32_t g0, g1, gl;
    uint64_t lines_scrolled;
    int32_t *sb_idx;
    int32_t *sb_free;
    int32_t sb_free_n;
    uint8_t *sb_wrap;
    int32_t sb_head, sb_len, sb_stride, scrollback_cap;
    jt_pen pen;
    jt_saved saved;
    uint32_t palette[256];
    uint32_t pal_overlay[16];
    uint16_t pal_overlay_mask;
    uint32_t default_fg, default_bg, cursor_color;
    uint16_t mouse_event;
    uint8_t mouse_sgr;
    uint8_t mouse_alt_scroll;
    uint8_t focus_event, bracketed_paste, sync_output, sync_flush;
    uint8_t reverse_video, cursor_visible, cursor_blink;
    uint8_t cursor_style;
    uint8_t decckm, deckpam;
    void *gp;
    void *rp;
    char *osc8_id;
    char *osc8_uri;
    int32_t pool_cells;
    uint32_t damage_gen;
    uint32_t last_print;
    uint8_t has_last_print;
} jt_scr;

typedef struct jt_rare {
    const char *osc8_id;
    const char *uri;
    uint32_t ul_color;
} jt_rare;

void jt_scr_init(jt_scr *s, int32_t cols, int32_t rows, int32_t sb_cap);
void jt_scr_deinit(jt_scr *s);
void jt_scr_resize(jt_scr *s, int32_t cols, int32_t rows);

void jt_scr_print_scalar(jt_scr *s, uint32_t scalar);
void jt_scr_print_run(jt_scr *s, const uint8_t *p, size_t n);

void jt_scr_index(jt_scr *s);
void jt_scr_ri(jt_scr *s);
void jt_scr_cr(jt_scr *s);
void jt_scr_nel(jt_scr *s);
void jt_scr_bs(jt_scr *s);
void jt_scr_tab(jt_scr *s);

void jt_scr_cup(jt_scr *s, int row, int col);
void jt_scr_el(jt_scr *s, int mode);
void jt_scr_ed(jt_scr *s, int mode);
void jt_scr_ech(jt_scr *s, int n);
void jt_scr_ich(jt_scr *s, int n);
void jt_scr_dch(jt_scr *s, int n);
void jt_scr_il(jt_scr *s, int n);
void jt_scr_dl(jt_scr *s, int n);
void jt_scr_decstbm(jt_scr *s, int top, int bot);

void jt_scr_switch_screen_mode(jt_scr *s, int mode, int enabled);
void jt_scr_cursor_copy(jt_buf *dst, const jt_buf *src);
void jt_scr_decsc(jt_scr *s);
void jt_scr_decrc(jt_scr *s);

void jt_scr_clear_history(jt_scr *s);
void jt_scr_copy_row(const jt_scr *s, int32_t y, Cell *dst, int32_t dst_cols, Cell blank);
void jt_scr_copy_sb_row(const jt_scr *s, int32_t i, Cell *dst, int32_t dst_cols, Cell blank);
int32_t jt_scr_sb_len(const jt_scr *s);
int jt_scr_sb_wrapped(const jt_scr *s, int32_t i);

void jt_scr_mark_dirty(jt_scr *s, int32_t y);
/* dst[y] = dirty[rowmap[y]] for y in [0, n); n is live rows. Zero dirty[0, grid_rows). */
void jt_scr_take_dirty(jt_scr *s, uint8_t *dst, int32_t n, uint32_t *damage_gen);
void jt_scr_wrap_at(jt_scr *s, int32_t y);
int jt_scr_is_wrapped(const jt_scr *s, int32_t y);

Cell *jt_scr_row(jt_scr *s, int32_t y);
void jt_scr_ris(jt_scr *s);
void jt_sync_set(jt_scr *s, int on);
int jt_sync_on(const jt_scr *s);
int jt_sync_flush(const jt_scr *s);
void jt_sync_clear_flush(jt_scr *s);
void jt_sync_timeout_clear(jt_scr *s);
void jt_scr_set_palette_overlay(jt_scr *s, const uint32_t rgb16[16], uint16_t mask);
void jt_scr_palette_reset(jt_scr *s);
void jt_sgr_apply(jt_scr *s, const uint16_t *p, int n, uint32_t seps);

extern const uint8_t jt_width_lut[278528];

static inline int jt_codepoint_width(uint32_t cp) {
    if (cp >= 0x110000u) return 1;
    uint8_t b = jt_width_lut[cp >> 2];
    return (int)((b >> ((cp & 3u) * 2u)) & 3u);
}
uint32_t jt_grapheme_intern(jt_scr *s, const uint32_t *cps, uint16_t n);
const uint32_t *jt_grapheme_get(const jt_scr *s, uint32_t id, uint16_t *n);
void jt_grapheme_retain(jt_scr *s, uint32_t id);
void jt_grapheme_release(jt_scr *s, uint32_t id);
uint16_t jt_rare_intern(jt_scr *s, const char *osc8_id, const char *uri, uint32_t ul);
int jt_rare_get(const jt_scr *s, uint16_t id, jt_rare *out);
void jt_rare_retain(jt_scr *s, uint16_t id);
void jt_rare_release(jt_scr *s, uint16_t id);
void jt_pen_refresh_extra(jt_scr *s);
void jt_scr_set_osc8(jt_scr *s, const char *id, const char *uri);
void jt_pools_init(jt_scr *s);
void jt_pools_deinit(jt_scr *s);

enum {
    JT_ST_GROUND = 0,
    JT_ST_ESCAPE,
    JT_ST_ESCAPE_INT,
    JT_ST_CSI_ENTRY,
    JT_ST_CSI_PARAM,
    JT_ST_CSI_INT,
    JT_ST_CSI_IGNORE,
    JT_ST_OSC_STRING,
    JT_ST_OSC_IGNORE,
    JT_ST_SOS_PM_APC,
    JT_ST_DCS_IGNORE,
};

typedef struct jt_vt_host {
    void *ctx;
    void (*write_pty)(void *ctx, const uint8_t *p, size_t n);
    void (*bell)(void *ctx);
    void (*set_title)(void *ctx, const uint8_t *utf8, size_t n);
    void (*osc52_write)(void *ctx, uint8_t kind, const uint8_t *b64, size_t n);
    void (*osc52_read)(void *ctx, uint8_t kind);
    void (*osc7)(void *ctx, const uint8_t *uri, size_t n);
    void (*osc133)(void *ctx, uint8_t action, const uint8_t *opts, size_t n);
    void (*palette_changed)(void *ctx);
    void (*size_report)(void *ctx, int kind);
    void (*history_cleared)(void *ctx);
    void (*notify)(void *ctx, const uint8_t *title, size_t nt,
                   const uint8_t *body, size_t nb);
    /* percent 255 = omitted. */
    void (*progress)(void *ctx, uint8_t state, uint8_t percent);
} jt_vt_host;

void jt_osc_dispatch(jt_scr *s, const jt_vt_host *h, const uint8_t *p, int n);

typedef struct jt_vt jt_vt;

jt_vt *jt_vt_create(void);
void jt_vt_destroy(jt_vt *p);
void jt_vt_reset(jt_vt *p);
void jt_vt_feed(jt_vt *p, const uint8_t *bytes, size_t n,
                jt_scr *scr, const jt_vt_host *host);
int jt_vt_state(const jt_vt *p);

size_t jt_scan_printable_ascii(const uint8_t *p, size_t n);
size_t jt_scan_until_c0(const uint8_t *p, size_t n);
size_t jt_scan_first_esc(const uint8_t *p, size_t n);
size_t jt_scan_ascii_no_acs(const uint8_t *p, size_t n);
uint32_t jt_acs_map(uint8_t b);
int jt_utf8_next(uint8_t *st, uint32_t *acc, uint8_t b, uint32_t *out);

#ifdef __cplusplus
}
#endif

#endif
