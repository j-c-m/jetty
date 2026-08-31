#ifndef JT_VT_INT_H
#define JT_VT_INT_H

#include "jt_img.h"
#include "jt_vt.h"

#define JT_MAX_PARAMS 24
#define JT_OSC_CAP 16384

struct jt_vt {
    int state;
    uint16_t params[JT_MAX_PARAMS];
    uint32_t seps;
    int np, param_empty;
    uint32_t param_acc;
    uint8_t inter[4];
    int ni;
    uint8_t osc[JT_OSC_CAP];
    int osc_n;
    uint32_t utf8_acc;
    uint8_t utf8_st;
    uint8_t *sync_buf;
    size_t sync_n, sync_cap;
    uint8_t syncing, sync_applying;
    uint8_t *apc;
    int apc_n, apc_cap;
    uint8_t apc_expect_g;
    uint8_t apc_ignore;
    uint8_t apc_esc;
    jt_img_loading load;
};

void jt_apc_begin(jt_vt *p);
void jt_apc_feed(jt_vt *p, const uint8_t *b, size_t n);
void jt_apc_finish(jt_vt *p, jt_scr *scr, const jt_vt_host *h);
void jt_apc_reset(jt_vt *p);

#endif
