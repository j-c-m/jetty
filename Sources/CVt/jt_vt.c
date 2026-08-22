#include "jt_vt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

#define JT_MAX_PARAMS 24

struct jt_vt {
    int state;
    uint16_t params[JT_MAX_PARAMS];
    uint32_t seps;
    int np, param_empty;
    uint32_t param_acc;
    uint8_t inter[4];
    int ni;
    uint8_t osc[4096];
    int osc_n;
    uint32_t utf8_acc;
    uint8_t utf8_st;
};

jt_vt *jt_vt_create(void) {
    jt_vt *p = (jt_vt *)calloc(1, sizeof *p);
    if (!p) return NULL;
    p->param_empty = 1;
    return p;
}

void jt_vt_destroy(jt_vt *p) { free(p); }

static void clear_seq(jt_vt *p) {
    p->ni = 0;
    p->np = 0;
    p->param_acc = 0;
    p->param_empty = 1;
    p->seps = 0;
}

void jt_vt_reset(jt_vt *p) {
    p->state = JT_ST_GROUND;
    p->utf8_acc = 0;
    p->utf8_st = 0;
    clear_seq(p);
    p->osc_n = 0;
}

int jt_vt_state(const jt_vt *p) { return p->state; }

static void finish_osc(jt_vt *p, jt_scr *scr, const jt_vt_host *h) {
    if (p->osc_n > 0) jt_osc_dispatch(scr, h, p->osc, p->osc_n);
    p->osc_n = 0;
}

static void enter_ground(jt_vt *p) {
    p->state = JT_ST_GROUND;
    clear_seq(p);
    p->osc_n = 0;
}

static void enter_escape(jt_vt *p) {
    clear_seq(p);
    p->state = JT_ST_ESCAPE;
}

static void enter_csi(jt_vt *p) {
    clear_seq(p);
    p->state = JT_ST_CSI_ENTRY;
}

static void utf8_reset(jt_vt *p) {
    p->utf8_acc = 0;
    p->utf8_st = 0;
}

static void start_param(jt_vt *p, uint8_t b) {
    p->param_acc = (uint32_t)(b - '0');
    p->param_empty = 0;
}

static void accum_param(jt_vt *p, uint8_t b) {
    if (p->param_empty) {
        start_param(p, b);
        return;
    }
    uint32_t v = p->param_acc * 10 + (uint32_t)(b - '0');
    p->param_acc = v > 65535 ? 65535 : v;
}

static void push_param(jt_vt *p, int colon) {
    if (p->np >= JT_MAX_PARAMS) {
        p->param_empty = 1;
        p->param_acc = 0;
        return;
    }
    if (colon) p->seps |= (1u << p->np);
    p->params[p->np++] = p->param_empty ? 0 : (uint16_t)p->param_acc;
    p->param_empty = 1;
    p->param_acc = 0;
}

static int pdef(const uint16_t *p, int n, int i, int d) {
    if (i < n) {
        int v = (int)p[i];
        return v == 0 ? d : v;
    }
    return d;
}

static void write_str(const jt_vt_host *h, const char *s) {
    if (!h || !h->write_pty || !s) return;
    size_t n = strlen(s);
    h->write_pty(h->ctx, (const uint8_t *)s, n);
}

static uint8_t priv_byte(const jt_vt *p) {
    return p->ni > 0 ? p->inter[0] : 0;
}

static int has_inter(const jt_vt *p, uint8_t b) {
    for (int i = 0; i < p->ni; i++) {
        if (p->inter[i] == b) return 1;
    }
    return 0;
}

static int dec_mode_state(const jt_scr *s, uint16_t mode) {
    int on = 0, known = 1, perm_reset = 0;
    switch (mode) {
    case 1: on = s && s->decckm; break;
    case 3: perm_reset = 1; break;
    case 5: on = s && s->reverse_video; break;
    case 6: on = s && s->origin_mode; break;
    case 7: on = !s || s->auto_wrap; break;
    case 9: on = s && s->mouse_event == 9; break;
    case 12: on = s && s->cursor_blink; break;
    case 25: on = !s || s->cursor_visible; break;
    case 47:
    case 1047:
    case 1049:
        on = s && s->in_alt;
        break;
    case 1000: on = s && s->mouse_event == 1000; break;
    case 1002: on = s && s->mouse_event == 1002; break;
    case 1003: on = s && s->mouse_event == 1003; break;
    case 1004: on = s && s->focus_event; break;
    case 1005: perm_reset = 1; break;
    case 1006: on = s && s->mouse_sgr; break;
    case 1007: on = !s || s->mouse_alt_scroll; break;
    case 1016: perm_reset = 1; break;
    case 1034: on = 0; break;
    case 2004: on = s && s->bracketed_paste; break;
    case 2026: on = s && s->sync_output; break;
    case 2027: perm_reset = 1; break;
    default: known = 0; break;
    }
    if (perm_reset) return 4;
    if (!known) return 0;
    return on ? 1 : 2;
}

static void reply_decrpm(const jt_vt_host *h, const jt_scr *s, int dec, uint16_t mode) {
    int st;
    if (!dec) {
        st = mode == 4 ? ((s && s->insert_mode) ? 1 : 2) : 0;
    } else {
        st = dec_mode_state(s, mode);
    }
    char buf[48];
    int n = dec
        ? snprintf(buf, sizeof buf, "\033[?%u;%d$y", (unsigned)mode, st)
        : snprintf(buf, sizeof buf, "\033[%u;%d$y", (unsigned)mode, st);
    if (n > 0) write_str(h, buf);
}

static void handle_csi(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t final) {
    uint8_t priv = priv_byte(p);
    if (final == 'p' && has_inter(p, '$')) {
        uint16_t mode = p->np > 0 ? p->params[0] : 0;
        reply_decrpm(h, scr, priv == '?', mode);
        return;
    }
    if (!scr) {
        if ((final == 'c' || final == 'n') && h && h->write_pty) {
            if (final == 'c' && priv == 0) write_str(h, "\033[?1;2c");
            if (final == 'c' && priv == '>') write_str(h, "\033[>0;0;0c");
        }
        return;
    }

    if (priv == '?') {
        if (final == 'h' || final == 'l') {
            int set = final == 'h';
            int count = p->np > 0 ? p->np : 1;
            for (int i = 0; i < count; i++) {
                uint16_t n = p->np > 0 ? p->params[i] : 0;
                switch (n) {
                case 1: scr->decckm = (uint8_t)set; break;
                case 5: scr->reverse_video = (uint8_t)set; break;
                case 6: scr->origin_mode = set; break;
                case 7: scr->auto_wrap = set; break;
                case 12: scr->cursor_blink = (uint8_t)set; break;
                case 25: scr->cursor_visible = (uint8_t)set; break;
                case 47:
                case 1047:
                case 1049:
                    jt_scr_switch_screen_mode(scr, (int)n, set);
                    break;
                case 9:
                    if (set) scr->mouse_event = 9;
                    else if (scr->mouse_event == 9) scr->mouse_event = 0;
                    break;
                case 1000:
                    if (set) scr->mouse_event = 1000;
                    else if (scr->mouse_event == 1000) scr->mouse_event = 0;
                    break;
                case 1002:
                    if (set) scr->mouse_event = 1002;
                    else if (scr->mouse_event == 1002) scr->mouse_event = 0;
                    break;
                case 1003:
                    if (set) scr->mouse_event = 1003;
                    else if (scr->mouse_event == 1003) scr->mouse_event = 0;
                    break;
                case 1004: scr->focus_event = (uint8_t)set; break;
                case 1006: scr->mouse_sgr = (uint8_t)set; break;
                case 1007: scr->mouse_alt_scroll = (uint8_t)set; break;
                case 2004: scr->bracketed_paste = (uint8_t)set; break;
                case 2026: scr->sync_output = (uint8_t)set; break;
                default: break;
                }
            }
        } else if (final == 'c') {
            /* DA1 with ? is not used; ignore */
        } else if (final == 'n') {
            if (pdef(p->params, p->np, 0, 0) == 6 && h && h->write_pty) {
                char buf[64];
                int r = scr->active->cy + 1;
                int c = scr->active->cx + 1;
                int n = snprintf(buf, sizeof buf, "\033[%d;%dR", r, c);
                if (n > 0) h->write_pty(h->ctx, (const uint8_t *)buf, (size_t)n);
            }
        }
        return;
    }

    if (priv == '>') {
        if (final == 'c') write_str(h, "\033[>0;0;0c");
        return;
    }
    if (priv == '=') return;

    switch (final) {
    case 'A':
        scr->active->pending_wrap = 0;
        scr->active->cy -= pdef(p->params, p->np, 0, 1);
        if (scr->active->cy < 0) scr->active->cy = 0;
        break;
    case 'B':
        scr->active->pending_wrap = 0;
        scr->active->cy += pdef(p->params, p->np, 0, 1);
        if (scr->active->cy > scr->rows - 1) scr->active->cy = scr->rows - 1;
        break;
    case 'C':
        scr->active->pending_wrap = 0;
        scr->active->cx += pdef(p->params, p->np, 0, 1);
        if (scr->active->cx > scr->cols - 1) scr->active->cx = scr->cols - 1;
        break;
    case 'D':
        scr->active->pending_wrap = 0;
        scr->active->cx -= pdef(p->params, p->np, 0, 1);
        if (scr->active->cx < 0) scr->active->cx = 0;
        break;
    case 'G':
        scr->active->pending_wrap = 0;
        scr->active->cx = pdef(p->params, p->np, 0, 1) - 1;
        if (scr->active->cx < 0) scr->active->cx = 0;
        if (scr->active->cx > scr->cols - 1) scr->active->cx = scr->cols - 1;
        break;
    case 'H':
    case 'f':
        jt_scr_cup(scr, pdef(p->params, p->np, 0, 1) - 1, pdef(p->params, p->np, 1, 1) - 1);
        break;
    case 'd':
        jt_scr_cup(scr, pdef(p->params, p->np, 0, 1) - 1, scr->active->cx);
        break;
    case 'J':
        jt_scr_ed(scr, pdef(p->params, p->np, 0, 0));
        break;
    case 'K':
        jt_scr_el(scr, pdef(p->params, p->np, 0, 0));
        break;
    case 'X':
        jt_scr_ech(scr, pdef(p->params, p->np, 0, 1));
        break;
    case 'L':
        jt_scr_il(scr, pdef(p->params, p->np, 0, 1));
        break;
    case 'M':
        jt_scr_dl(scr, pdef(p->params, p->np, 0, 1));
        break;
    case '@':
        jt_scr_ich(scr, pdef(p->params, p->np, 0, 1));
        break;
    case 'P':
        jt_scr_dch(scr, pdef(p->params, p->np, 0, 1));
        break;
    case 'S': {
        int n = pdef(p->params, p->np, 0, 1);
        for (int i = 0; i < n; i++) jt_scr_index(scr);
        break;
    }
    case 'T': {
        int n = pdef(p->params, p->np, 0, 1);
        for (int i = 0; i < n; i++) jt_scr_ri(scr);
        break;
    }
    case 'Z': {
        jt_buf *b = scr->active;
        b->pending_wrap = 0;
        int x = b->cx - 1;
        while (x > 0 && !b->tabstops[x]) x--;
        b->cx = x < 0 ? 0 : x;
        break;
    }
    case 'c':
        if (priv == 0) write_str(h, "\033[?1;2c");
        break;
    case 'n':
        if (pdef(p->params, p->np, 0, 0) == 5) write_str(h, "\033[0n");
        else if (pdef(p->params, p->np, 0, 0) == 6 && h && h->write_pty) {
            char buf[64];
            int r = scr->active->cy + 1;
            int c = scr->active->cx + 1;
            int n = snprintf(buf, sizeof buf, "\033[%d;%dR", r, c);
            if (n > 0) h->write_pty(h->ctx, (const uint8_t *)buf, (size_t)n);
        }
        break;
    case 'g': {
        int n = pdef(p->params, p->np, 0, 0);
        jt_buf *b = scr->active;
        if (n == 3) {
            for (int i = 0; i < scr->cols; i++) b->tabstops[i] = 0;
        } else if (b->cx >= 0 && b->cx < scr->cols) {
            b->tabstops[b->cx] = 0;
        }
        break;
    }
    case 'r': {
        int top = pdef(p->params, p->np, 0, 1) - 1;
        int bot = (p->np > 1 ? (int)p->params[1] : scr->rows) - 1;
        if (p->np < 2 || p->params[1] == 0) bot = scr->rows - 1;
        jt_scr_decstbm(scr, top, bot);
        break;
    }
    case 'h':
        for (int i = 0; i < (p->np > 0 ? p->np : 1); i++) {
            if ((p->np > 0 ? p->params[i] : 0) == 4) scr->insert_mode = 1;
        }
        break;
    case 'l':
        for (int i = 0; i < (p->np > 0 ? p->np : 1); i++) {
            if ((p->np > 0 ? p->params[i] : 0) == 4) scr->insert_mode = 0;
        }
        break;
    case 'm':
        jt_sgr_apply(scr, p->params, p->np, p->seps);
        break;
    case 'q':
        if (p->ni == 1 && p->inter[0] == ' ') {
            int n = pdef(p->params, p->np, 0, 0);
            if (n >= 0 && n <= 6) scr->cursor_style = (uint8_t)n;
        }
        break;
    case 't':
        if (p->np > 1) break;
        {
            int kind = pdef(p->params, p->np, 0, 0);
            if ((kind == 14 || kind == 18) && h && h->size_report)
                h->size_report(h->ctx, kind);
        }
        break;
    default:
        break;
    }
}

static void handle_esc(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t final) {
    if (!scr) {
        if (final == 'Z') write_str(h, "\033[?1;2c");
        return;
    }
    if (p->ni == 0) {
        switch (final) {
        case 'c':
            utf8_reset(p);
            jt_scr_ris(scr);
            break;
        case 'D':
            jt_scr_index(scr);
            break;
        case 'E':
            jt_scr_nel(scr);
            break;
        case 'H':
            if (scr->active->cx >= 0 && scr->active->cx < scr->cols)
                scr->active->tabstops[scr->active->cx] = 1;
            break;
        case 'M':
            jt_scr_ri(scr);
            break;
        case '7':
            jt_scr_decsc(scr);
            break;
        case '8':
            jt_scr_decrc(scr);
            break;
        case 'Z':
            write_str(h, "\033[?1;2c");
            break;
        case '=':
            scr->deckpam = 1;
            break;
        case '>':
            scr->deckpam = 0;
            break;
        default:
            break;
        }
        return;
    }
    if (p->ni == 1 && (p->inter[0] == '(' || p->inter[0] == ')')) {
        int slot = final == '0' ? 1 : 0;
        if (p->inter[0] == '(') scr->g0 = slot;
        else scr->g1 = slot;
    }
}

static void finish_csi(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t final) {
    handle_csi(p, scr, h, final);
    enter_ground(p);
}

static int try_fast_csi(jt_vt *p, jt_scr *scr, const jt_vt_host *h,
                        const uint8_t *bytes, size_t *i, size_t n) {
    size_t start = *i;
    if (start >= n || bytes[start] != '[') return 0;
    size_t j = start + 1;
    if (j >= n) return 0;
    uint8_t first = bytes[j];
    if ((first >= 0x3C && first <= 0x3F) || (first >= 0x20 && first <= 0x2F))
        return 0;
    clear_seq(p);
    int saw = 0;
    while (j < n) {
        uint8_t b = bytes[j];
        if (b >= '0' && b <= '9') {
            accum_param(p, b);
            saw = 1;
            j++;
            continue;
        }
        if (b == ';' || b == ':') {
            push_param(p, b == ':');
            saw = 1;
            j++;
            continue;
        }
        if (b >= 0x40 && b <= 0x7E) {
            if (saw || !p->param_empty) push_param(p, 0);
            *i = j + 1;
            finish_csi(p, scr, h, b);
            return 1;
        }
        return 0;
    }
    return 0;
}

#if defined(__ARM_NEON)
/* Five well-formed 3-byte scalars. Leads E1–EC or EE–EF. Load 16, consume 15. */
static int try_neon_utf8_3(const uint8_t *p, uint32_t cps[5]) {
    const uint8x16_t v = vld1q_u8(p);
    const uint8x16_t idx_lead = {
        0, 3, 6, 9, 12, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255};
    const uint8x16_t idx_c1 = {
        1, 4, 7, 10, 13, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255};
    const uint8x16_t idx_c2 = {
        2, 5, 8, 11, 14, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255};
    uint8x16_t lead = vqtbl1q_u8(v, idx_lead);
    uint8x16_t c1 = vqtbl1q_u8(v, idx_c1);
    uint8x16_t c2 = vqtbl1q_u8(v, idx_c2);
    uint8x16_t lead_ok = vandq_u8(
        vcleq_u8(vsubq_u8(lead, vdupq_n_u8(0xE1)), vdupq_n_u8(0x0E)),
        vmvnq_u8(vceqq_u8(lead, vdupq_n_u8(0xED))));
    uint8x16_t c80 = vdupq_n_u8(0x80);
    uint8x16_t cmask = vdupq_n_u8(0xC0);
    uint8x16_t cont_ok = vandq_u8(
        vceqq_u8(vandq_u8(c1, cmask), c80),
        vceqq_u8(vandq_u8(c2, cmask), c80));
    uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(vandq_u8(lead_ok, cont_ok)), 0);
    if ((lo & 0xFFFFFFFFFFull) != 0xFFFFFFFFFFull) return 0;

    uint16x8_t l16 = vmovl_u8(vget_low_u8(vandq_u8(lead, vdupq_n_u8(0x0F))));
    uint16x8_t a16 = vmovl_u8(vget_low_u8(vandq_u8(c1, vdupq_n_u8(0x3F))));
    uint16x8_t b16 = vmovl_u8(vget_low_u8(vandq_u8(c2, vdupq_n_u8(0x3F))));
    uint32x4_t cp0 = vorrq_u32(
        vshlq_n_u32(vmovl_u16(vget_low_u16(l16)), 12),
        vorrq_u32(
            vshlq_n_u32(vmovl_u16(vget_low_u16(a16)), 6),
            vmovl_u16(vget_low_u16(b16))));
    cps[0] = vgetq_lane_u32(cp0, 0);
    cps[1] = vgetq_lane_u32(cp0, 1);
    cps[2] = vgetq_lane_u32(cp0, 2);
    cps[3] = vgetq_lane_u32(cp0, 3);
    cps[4] = ((uint32_t)vgetq_lane_u16(l16, 4) << 12)
        | ((uint32_t)vgetq_lane_u16(a16, 4) << 6)
        | (uint32_t)vgetq_lane_u16(b16, 4);
    return 1;
}
#endif

static void emit_utf8_run(jt_vt *p, jt_scr *scr, const uint8_t *src, size_t n) {
    if (!scr) return;
    size_t j = 0;
    while (j < n) {
        if (p->utf8_st == 0) {
            uint8_t b0 = src[j];
            if (b0 < 0x80) {
                if (b0 >= 0x20 && b0 != 0x7F) {
                    jt_scr_print_scalar(scr, b0);
                    j++;
                    continue;
                }
                break;
            }
#if defined(__ARM_NEON)
            if ((b0 & 0xF0) == 0xE0 && j + 16 <= n) {
                uint32_t cps[5];
                if (try_neon_utf8_3(src + j, cps)) {
                    do {
                        jt_scr_print_scalar(scr, cps[0]);
                        jt_scr_print_scalar(scr, cps[1]);
                        jt_scr_print_scalar(scr, cps[2]);
                        jt_scr_print_scalar(scr, cps[3]);
                        jt_scr_print_scalar(scr, cps[4]);
                        j += 15;
                        if (j + 16 > n) break;
                    } while (try_neon_utf8_3(src + j, cps));
                    continue;
                }
            }
#endif
            if ((b0 & 0xE0) == 0xC0 && b0 >= 0xC2 && j + 1 < n) {
                uint8_t b1 = src[j + 1];
                if ((b1 & 0xC0) == 0x80) {
                    jt_scr_print_scalar(scr, ((uint32_t)(b0 & 0x1F) << 6) | (b1 & 0x3F));
                    j += 2;
                    continue;
                }
            } else if ((b0 & 0xF0) == 0xE0 && j + 2 < n) {
                uint8_t b1 = src[j + 1], b2 = src[j + 2];
                if ((b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80) {
                    uint32_t cp = ((uint32_t)(b0 & 0x0F) << 12)
                        | ((uint32_t)(b1 & 0x3F) << 6) | (b2 & 0x3F);
                    int ok = (b0 == 0xE0) ? (b1 >= 0xA0)
                        : (b0 == 0xED) ? (b1 < 0xA0)
                        : 1;
                    if (ok && cp >= 0x800) {
                        jt_scr_print_scalar(scr, cp);
                        j += 3;
                        continue;
                    }
                }
            } else if ((b0 & 0xF8) == 0xF0 && b0 <= 0xF4 && j + 3 < n) {
                uint8_t b1 = src[j + 1], b2 = src[j + 2], b3 = src[j + 3];
                if ((b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80 && (b3 & 0xC0) == 0x80) {
                    uint32_t cp = ((uint32_t)(b0 & 0x07) << 18)
                        | ((uint32_t)(b1 & 0x3F) << 12)
                        | ((uint32_t)(b2 & 0x3F) << 6) | (b3 & 0x3F);
                    int ok = (b0 == 0xF0) ? (b1 >= 0x90)
                        : (b0 == 0xF4) ? (b1 < 0x90)
                        : 1;
                    if (ok && cp >= 0x10000 && cp <= 0x10FFFF) {
                        jt_scr_print_scalar(scr, cp);
                        j += 4;
                        continue;
                    }
                }
            }
        }
        uint32_t cp = 0;
        int r = jt_utf8_next(&p->utf8_st, &p->utf8_acc, src[j], &cp);
        if (r == 1 || r == 2) jt_scr_print_scalar(scr, cp);
        if (r != 2) j++;
    }
}

static void execute_c0(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t b) {
    if (b == 0x07) {
        if (p->state == JT_ST_OSC_STRING) finish_osc(p, scr, h);
        if (p->state == JT_ST_OSC_STRING || p->state == JT_ST_OSC_IGNORE) {
            enter_ground(p);
            return;
        }
        if (h && h->bell) h->bell(h->ctx);
        return;
    }
    if (b == 0x1B) {
        if (p->state == JT_ST_OSC_STRING) finish_osc(p, scr, h);
        utf8_reset(p);
        enter_escape(p);
        return;
    }
    if (b == 0x18 || b == 0x1A) {
        utf8_reset(p);
        enter_ground(p);
        if (b == 0x1A && scr) jt_scr_print_scalar(scr, 0xFFFD);
        return;
    }
    if (b == 0x7F) return;
    if (!scr) return;
    switch (b) {
    case 0x08: jt_scr_bs(scr); break;
    case 0x09: jt_scr_tab(scr); break;
    case 0x0A:
    case 0x0B:
    case 0x0C:
        jt_scr_index(scr);
        break;
    case 0x0D: jt_scr_cr(scr); break;
    case 0x0E: scr->gl = 1; break;
    case 0x0F: scr->gl = 0; break;
    default: break;
    }
}

static int gl_is_ascii(const jt_scr *scr) {
    if (!scr) return 1;
    int slot = scr->gl == 0 ? scr->g0 : scr->g1;
    return slot == 0;
}

static void dispatch(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t b);

static void escape_byte(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t b) {
    switch (b) {
    case '[': enter_csi(p); break;
    case ']':
        p->osc_n = 0;
        p->state = JT_ST_OSC_STRING;
        break;
    case 'P':
        p->osc_n = 0;
        p->state = JT_ST_DCS_IGNORE;
        break;
    case 'X':
    case '^':
    case '_':
        p->osc_n = 0;
        p->state = JT_ST_SOS_PM_APC;
        break;
    default:
        if (b >= 0x20 && b <= 0x2F) {
            p->inter[0] = b;
            p->ni = 1;
            p->state = JT_ST_ESCAPE_INT;
        } else if (b >= 0x30 && b <= 0x7E) {
            handle_esc(p, scr, h, b);
            enter_ground(p);
        } else {
            enter_ground(p);
        }
        break;
    }
}

static void escape_int_byte(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t b) {
    if (b >= 0x20 && b <= 0x2F) {
        if (p->ni < 4) p->inter[p->ni++] = b;
        return;
    }
    if (b >= 0x30 && b <= 0x7E) {
        handle_esc(p, scr, h, b);
        enter_ground(p);
        return;
    }
    enter_ground(p);
}

static void csi_entry(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t b) {
    if (b >= '0' && b <= '9') {
        start_param(p, b);
        p->state = JT_ST_CSI_PARAM;
        return;
    }
    if (b == ';' || b == ':') {
        push_param(p, b == ':');
        p->state = JT_ST_CSI_PARAM;
        return;
    }
    if (b == '?' || b == '>' || b == '=' || b == '<') {
        p->inter[0] = b;
        p->ni = 1;
        p->state = JT_ST_CSI_PARAM;
        return;
    }
    if (b >= 0x20 && b <= 0x2F) {
        if (p->ni < 4) p->inter[p->ni++] = b;
        p->state = JT_ST_CSI_INT;
        return;
    }
    if (b >= 0x40 && b <= 0x7E) {
        finish_csi(p, scr, h, b);
        return;
    }
}

static void csi_param(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t b) {
    if (b >= '0' && b <= '9') {
        accum_param(p, b);
        return;
    }
    if (b == ';' || b == ':') {
        push_param(p, b == ':');
        return;
    }
    if (b >= 0x20 && b <= 0x2F) {
        push_param(p, 0);
        if (p->ni < 4) p->inter[p->ni++] = b;
        p->state = JT_ST_CSI_INT;
        return;
    }
    if (b >= 0x40 && b <= 0x7E) {
        push_param(p, 0);
        finish_csi(p, scr, h, b);
        return;
    }
    if (b >= 0x3C && b <= 0x3F) p->state = JT_ST_CSI_IGNORE;
}

static void dispatch(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t b) {
    if (b == 0x18 || b == 0x1A) {
        utf8_reset(p);
        enter_ground(p);
        if (b == 0x1A && scr) jt_scr_print_scalar(scr, 0xFFFD);
        return;
    }
    if (b == 0x1B) {
        if (p->state == JT_ST_OSC_STRING) finish_osc(p, scr, h);
        utf8_reset(p);
        enter_escape(p);
        return;
    }
    int in_string = p->state == JT_ST_OSC_STRING || p->state == JT_ST_OSC_IGNORE
        || p->state == JT_ST_SOS_PM_APC || p->state == JT_ST_DCS_IGNORE;
    if (b < 0x20 && !in_string) {
        execute_c0(p, scr, h, b);
        return;
    }
    switch (p->state) {
    case JT_ST_ESCAPE:
        escape_byte(p, scr, h, b);
        break;
    case JT_ST_ESCAPE_INT:
        escape_int_byte(p, scr, h, b);
        break;
    case JT_ST_CSI_ENTRY:
        csi_entry(p, scr, h, b);
        break;
    case JT_ST_CSI_PARAM:
        csi_param(p, scr, h, b);
        break;
    case JT_ST_CSI_INT:
        if (b >= 0x20 && b <= 0x2F) {
            if (p->ni < 4) p->inter[p->ni++] = b;
        } else if (b >= 0x40 && b <= 0x7E) {
            finish_csi(p, scr, h, b);
        } else if (b >= 0x30 && b <= 0x3F) {
            p->state = JT_ST_CSI_IGNORE;
        }
        break;
    case JT_ST_CSI_IGNORE:
        if (b >= 0x40 && b <= 0x7E) enter_ground(p);
        break;
    case JT_ST_OSC_STRING:
        if (b == 0x07) {
            finish_osc(p, scr, h);
            enter_ground(p);
        } else if (p->osc_n >= 4096) p->state = JT_ST_OSC_IGNORE;
        else p->osc[p->osc_n++] = b;
        break;
    case JT_ST_OSC_IGNORE:
        if (b == 0x07) enter_ground(p);
        break;
    case JT_ST_SOS_PM_APC:
    case JT_ST_DCS_IGNORE:
        if (b == 0x07) enter_ground(p);
        break;
    default:
        break;
    }
}

void jt_vt_feed(jt_vt *p, const uint8_t *bytes, size_t n,
                jt_scr *scr, const jt_vt_host *host) {
    size_t i = 0;
    while (i < n) {
        if (p->state == JT_ST_GROUND) {
            uint8_t b = bytes[i];
            if (b == 0x1B) {
                size_t j = i + 1;
                if (try_fast_csi(p, scr, host, bytes, &j, n)) {
                    i = j;
                    continue;
                }
                execute_c0(p, scr, host, 0x1B);
                i++;
                continue;
            }
            if (b < 0x20 || b == 0x7F) {
                execute_c0(p, scr, host, b);
                i++;
                continue;
            }
            size_t rest = n - i;
            const uint8_t *sp = bytes + i;
            if (gl_is_ascii(scr)) {
                size_t ascii = jt_scan_printable_ascii(sp, rest);
                if (ascii > 0) {
                    if (scr) jt_scr_print_run(scr, sp, ascii);
                    i += ascii;
                    continue;
                }
                size_t m = jt_scan_until_c0(sp, rest);
                emit_utf8_run(p, scr, sp, m);
                i += m;
                continue;
            }
            size_t low = jt_scan_ascii_no_acs(sp, rest);
            if (low > 0) {
                if (scr) jt_scr_print_run(scr, sp, low);
                i += low;
                continue;
            }
            if (b >= 0x60 && b <= 0x7E) {
                if (scr) jt_scr_print_scalar(scr, jt_acs_map(b));
                i++;
                continue;
            }
            size_t m = jt_scan_until_c0(sp, rest);
            emit_utf8_run(p, scr, sp, m);
            i += m;
            continue;
        }
        dispatch(p, scr, host, bytes[i]);
        i++;
    }
}
