#ifndef JT_VT_H
#define JT_VT_H

#include "jt_cell.h"

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
    int32_t origin;
    int32_t cx, cy, pending_wrap;
    int32_t scroll_top, scroll_bottom;
    uint8_t *tabstops;
    uint8_t *dirty;
    uint8_t *wrap;
} jt_buf;

typedef struct jt_scr {
    jt_buf primary, alt;
    jt_buf *active;
    int32_t cols, rows;
    int32_t in_alt;
    int32_t auto_wrap, insert_mode, origin_mode;
    int32_t g0, g1, gl;
    uint64_t lines_scrolled;
    Cell *sb;
    uint8_t *sb_wrap;
    int32_t sb_head, sb_len, sb_stride, scrollback_cap;
    jt_pen pen;
    jt_saved saved;
    uint32_t palette[256];
    uint32_t default_fg, default_bg, cursor_color;
    uint8_t mouse_event;
    uint8_t mouse_sgr;
    uint8_t mouse_alt_scroll;
    uint8_t focus_event, bracketed_paste, sync_output;
    uint8_t reverse_video, cursor_visible, cursor_blink;
    uint8_t cursor_style;
    uint8_t decckm, deckpam;
} jt_scr;

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

void jt_scr_mark_dirty(jt_scr *s, int32_t y);
void jt_scr_wrap_at(jt_scr *s, int32_t y);
int jt_scr_is_wrapped(const jt_scr *s, int32_t y);

Cell *jt_scr_row(jt_scr *s, int32_t y);

#ifdef __cplusplus
}
#endif

#endif
