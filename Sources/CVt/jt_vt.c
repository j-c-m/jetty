#include "jt_vt_int.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

#define JT_SYNC_BUF 0x200000
#define JT_SYNC_ESC 8

static const uint8_t JT_BSU[JT_SYNC_ESC] = {0x1B, '[', '?', '2', '0', '2', '6', 'h'};
static const uint8_t JT_ESU[JT_SYNC_ESC] = {0x1B, '[', '?', '2', '0', '2', '6', 'l'};

void jt_sync_set(jt_scr *s, int on) {
    if (!s) return;
    if (on) {
        __atomic_store_n(&s->sync_output, 1, __ATOMIC_RELEASE);
        __atomic_fetch_add(&s->sync_epoch, 1, __ATOMIC_RELEASE);
    } else {
        __atomic_store_n(&s->sync_output, 0, __ATOMIC_RELEASE);
    }
}

int jt_sync_on(const jt_scr *s) {
    return s && __atomic_load_n(&s->sync_output, __ATOMIC_ACQUIRE);
}

uint32_t jt_sync_epoch(const jt_scr *s) {
    return s ? __atomic_load_n(&s->sync_epoch, __ATOMIC_ACQUIRE) : 0;
}

void jt_sync_timeout_clear(jt_scr *s) {
    if (s) __atomic_store_n(&s->sync_output, 0, __ATOMIC_RELEASE);
}

jt_vt *jt_vt_create(void) {
    jt_vt *p = (jt_vt *)calloc(1, sizeof *p);
    if (!p) return NULL;
    p->param_empty = 1;
    return p;
}

void jt_vt_destroy(jt_vt *p) {
    if (!p) return;
    jt_apc_reset(p);
    free(p->sync_buf);
    free(p);
}

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
    p->sync_n = 0;
    p->syncing = 0;
    p->sync_applying = 0;
    clear_seq(p);
    p->osc_n = 0;
    p->apc_n = 0;
    p->apc_ignore = 0;
    p->apc_expect_g = 0;
    p->apc_esc = 0;
    jt_img_abort_loading(&p->load);
}

int jt_vt_state(const jt_vt *p) { return p->state; }

static void write_str(const jt_vt_host *h, const char *s);

static void finish_osc(jt_vt *p, jt_scr *scr, const jt_vt_host *h) {
    if (p->osc_n > 0) jt_osc_dispatch(scr, h, p->osc, p->osc_n);
    p->osc_n = 0;
}

static int dcs_hex_nibble(uint8_t b) {
    if (b >= '0' && b <= '9') return b - '0';
    if (b >= 'a' && b <= 'f') return b - 'a' + 10;
    if (b >= 'A' && b <= 'F') return b - 'A' + 10;
    return -1;
}

static int dcs_hex_decode(const uint8_t *p, int n, char *out, int cap) {
    int o = 0;
    for (int i = 0; i + 1 < n && o + 1 < cap; i += 2) {
        int hi = dcs_hex_nibble(p[i]);
        int lo = dcs_hex_nibble(p[i + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[o++] = (char)((hi << 4) | lo);
    }
    out[o] = 0;
    return o;
}

static int dcs_hex_encode(const char *s, char *out, int cap) {
    static const char *hex = "0123456789ABCDEF";
    int o = 0;
    for (int i = 0; s[i] && o + 2 < cap; i++) {
        unsigned b = (unsigned char)s[i];
        out[o++] = hex[b >> 4];
        out[o++] = hex[b & 15];
    }
    out[o] = 0;
    return o;
}

static const char *xtgettcap_val(const char *key) {
    if (!strcmp(key, "colors")) return "256";
    if (!strcmp(key, "pairs")) return "32767";
    if (!strcmp(key, "TN") || !strcmp(key, "name")) return "xterm-256color";
    if (!strcmp(key, "Tc")) return "";
    if (!strcmp(key, "RGB")) return "8";
    if (!strcmp(key, "kbs")) return "\x7f";
    if (!strcmp(key, "smxx")) return "\033[9m";
    if (!strcmp(key, "rmxx")) return "\033[29m";
    if (!strcmp(key, "sitm")) return "\033[3m";
    if (!strcmp(key, "ritm")) return "\033[23m";
    if (!strcmp(key, "smul")) return "\033[4m";
    if (!strcmp(key, "rmul")) return "\033[24m";
    if (!strcmp(key, "Smulx")) return "\033[4:%p1%dm";
    if (!strcmp(key, "Setulc")) return "\033[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%d%;m";
    if (!strcmp(key, "Sync")) return "\033[?2026%?%p1%{1}%-%tl%eh%;";
    if (!strcmp(key, "Ms")) return "\033]52;%p1%s;%p2%s\007";
    return NULL;
}

static void finish_dcs(jt_vt *p, jt_scr *scr, const jt_vt_host *h) {
    const uint8_t *d = p->osc;
    int n = p->osc_n;
    p->osc_n = 0;
    if (!h || !h->write_pty || n < 2) return;
    if (d[0] == '+' && d[1] == 'q') {
        int i = 2;
        int any = 0;
        while (i < n) {
            int start = i;
            while (i < n && d[i] != ';') i++;
            char key[64];
            if (dcs_hex_decode(d + start, i - start, key, (int)sizeof key) > 0) {
                const char *val = xtgettcap_val(key);
                if (val) {
                    char kh[128], vh[256], out[512];
                    dcs_hex_encode(key, kh, (int)sizeof kh);
                    dcs_hex_encode(val, vh, (int)sizeof vh);
                    int w = val[0]
                        ? snprintf(out, sizeof out, "\033P1+r%s=%s\033\\", kh, vh)
                        : snprintf(out, sizeof out, "\033P1+r%s\033\\", kh);
                    if (w > 0 && (size_t)w < sizeof out) {
                        write_str(h, out);
                        any = 1;
                    }
                }
            }
            if (i < n && d[i] == ';') i++;
        }
        if (!any) write_str(h, "\033P0+r\033\\");
        return;
    }
    if (d[0] == '$' && d[1] == 'q' && scr) {
        const uint8_t *q = d + 2;
        int qn = n - 2;
        char buf[128];
        int w = 0;
        if (qn == 1 && q[0] == 'm') {
            char body[96];
            int bl = jt_sgr_encode(scr, body, (int)sizeof body);
            if (bl < 0) w = snprintf(buf, sizeof buf, "\033P0$r\033\\");
            else w = snprintf(buf, sizeof buf, "\033P1$r%sm\033\\", body);
        } else if (qn == 1 && q[0] == 'r') {
            int top = scr->active->scroll_top + 1;
            int bot = scr->active->scroll_bottom + 1;
            w = snprintf(buf, sizeof buf, "\033P1$r%d;%dr\033\\", top, bot);
        } else if (qn == 2 && q[0] == ' ' && q[1] == 'q') {
            w = snprintf(buf, sizeof buf, "\033P1$r%d q\033\\", (int)scr->cursor_style);
        } else {
            w = snprintf(buf, sizeof buf, "\033P0$r\033\\");
        }
        if (w > 0) h->write_pty(h->ctx, (const uint8_t *)buf, (size_t)w);
    }
}

static void enter_ground(jt_vt *p) {
    p->state = JT_ST_GROUND;
    clear_seq(p);
    p->osc_n = 0;
    p->apc_esc = 0;
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

/* DCS > | <name version> ST. Product name; TERM_PROGRAM stays jetty. */
static void write_xtversion(const jt_vt_host *h) {
    char buf[64];
    int n = snprintf(buf, sizeof buf, "\033P>|" JT_APP_NAME " %s\033\\", JT_VERSION);
    if (n > 0) write_str(h, buf);
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
    case 45: on = s && s->reverse_wrap; break;
    case 66: on = s && s->deckpam; break;
    case 1045: on = s && s->reverse_wrap_ext; break;
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
    case 1036: on = !s || s->alt_esc; break;
    case 2004: on = s && s->bracketed_paste; break;
    case 2031: on = s && s->report_theme; break;
    case 2033: on = s && s->report_vis; break;
    case 2048: on = s && s->inband_size; break;
    case 2026: on = jt_sync_on(s); break;
    case 2027: on = s && s->mode_2027; break;
    default: known = 0; break;
    }
    if (perm_reset) return 4;
    if (!known) return 0;
    return on ? 1 : 2;
}

static void reply_decrpm(const jt_vt_host *h, const jt_scr *s, int dec, uint16_t mode) {
    int st;
    if (!dec) {
        if (mode == 4) st = (s && s->insert_mode) ? 1 : 2;
        else if (mode == 20) st = (s && s->linefeed_nl) ? 1 : 2;
        else st = 0;
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
        if ((final == 'c' || final == 'n' || final == 'q') && h && h->write_pty) {
            if (final == 'c' && priv == 0) write_str(h, "\033[?1;2c");
            if (final == 'c' && priv == '>') write_str(h, "\033[>0;0;0c");
            if (final == 'q' && priv == '>') write_xtversion(h);
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
                case 45: scr->reverse_wrap = (uint8_t)set; break;
                case 66: scr->deckpam = (uint8_t)set; break;
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
                case 1036: scr->alt_esc = (uint8_t)set; break;
                case 1045: scr->reverse_wrap_ext = (uint8_t)set; break;
                case 1048:
                    if (set) jt_scr_decsc(scr);
                    else jt_scr_decrc(scr);
                    break;
                case 2004: scr->bracketed_paste = (uint8_t)set; break;
                case 2026:
                    if (p->sync_applying) break;
                    jt_sync_set(scr, set);
                    if (set) p->syncing = 1;
                    break;
                case 2027: jt_scr_set_mode_2027(scr, set); break;
                case 2031: scr->report_theme = (uint8_t)set; break;
                case 2033: scr->report_vis = (uint8_t)set; break;
                case 2048:
                    scr->inband_size = (uint8_t)set;
                    if (set && h && h->size_report) h->size_report(h->ctx, 48);
                    break;
                default: break;
                }
            }
        } else if (final == 'c') {
            /* DA1 with ? is not used; ignore */
        } else if (final == 'n') {
            int q = pdef(p->params, p->np, 0, 0);
            if (q == 6 && h && h->write_pty) {
                char buf[64];
                int r = scr->active->cy + 1;
                int c = scr->active->cx + 1;
                int n = snprintf(buf, sizeof buf, "\033[%d;%dR", r, c);
                if (n > 0) h->write_pty(h->ctx, (const uint8_t *)buf, (size_t)n);
            } else if (q == 996) {
                write_str(h, "\033[?997;1n");
            } else if (q == 998) {
                write_str(h, "\033[?999;1n");
            }
        } else if (final == 's' || final == 'r') {
            int restore = final == 'r';
            int count = p->np > 0 ? p->np : 0;
            for (int i = 0; i < count; i++) {
                uint16_t n = p->params[i];
                int bit = -1;
                uint8_t cur = 0;
                switch (n) {
                case 1: bit = 0; cur = scr->decckm; break;
                case 5: bit = 1; cur = scr->reverse_video; break;
                case 6: bit = 2; cur = (uint8_t)scr->origin_mode; break;
                case 7: bit = 3; cur = (uint8_t)scr->auto_wrap; break;
                case 12: bit = 4; cur = scr->cursor_blink; break;
                case 25: bit = 5; cur = scr->cursor_visible; break;
                case 45: bit = 6; cur = scr->reverse_wrap; break;
                case 66: bit = 7; cur = scr->deckpam; break;
                case 1045: bit = 8; cur = scr->reverse_wrap_ext; break;
                default: break;
                }
                if (bit < 0) continue;
                uint16_t mask = (uint16_t)(1u << bit);
                if (restore) {
                    if (!(scr->xtsave_valid & mask)) continue;
                    cur = scr->xtsave[bit];
                    switch (n) {
                    case 1: scr->decckm = cur; break;
                    case 5: scr->reverse_video = cur; break;
                    case 6: scr->origin_mode = cur; break;
                    case 7: scr->auto_wrap = cur; break;
                    case 12: scr->cursor_blink = cur; break;
                    case 25: scr->cursor_visible = cur; break;
                    case 45: scr->reverse_wrap = cur; break;
                    case 66: scr->deckpam = cur; break;
                    case 1045: scr->reverse_wrap_ext = cur; break;
                    default: break;
                    }
                } else {
                    scr->xtsave[bit] = cur;
                    scr->xtsave_valid |= mask;
                }
            }
        }
        return;
    }

    if (priv == '>') {
        if (final == 'c') write_str(h, "\033[>0;0;0c");
        else if (final == 'q') write_xtversion(h);
        return;
    }
    if (priv == '=') return;

    switch (final) {
    case 'k':
    case 'A':
        scr->active->pending_wrap = 0;
        scr->active->cy -= pdef(p->params, p->np, 0, 1);
        if (scr->active->cy < 0) scr->active->cy = 0;
        break;
    case 'e':
    case 'B':
        scr->active->pending_wrap = 0;
        scr->active->cy += pdef(p->params, p->np, 0, 1);
        if (scr->active->cy > scr->rows - 1) scr->active->cy = scr->rows - 1;
        break;
    case 'a':
    case 'C':
        scr->active->pending_wrap = 0;
        scr->active->cx += pdef(p->params, p->np, 0, 1);
        if (scr->active->cx > scr->cols - 1) scr->active->cx = scr->cols - 1;
        break;
    case 'j':
    case 'D':
        jt_scr_cub(scr, pdef(p->params, p->np, 0, 1));
        break;
    case 'E':
        scr->active->pending_wrap = 0;
        scr->active->cy += pdef(p->params, p->np, 0, 1);
        if (scr->active->cy > scr->rows - 1) scr->active->cy = scr->rows - 1;
        jt_scr_cr(scr);
        break;
    case 'F':
        scr->active->pending_wrap = 0;
        scr->active->cy -= pdef(p->params, p->np, 0, 1);
        if (scr->active->cy < 0) scr->active->cy = 0;
        jt_scr_cr(scr);
        break;
    case 'I': {
        int n = pdef(p->params, p->np, 0, 1);
        for (int i = 0; i < n; i++) jt_scr_tab(scr);
        break;
    }
    case '`':
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
    case 'J': {
        int mode = pdef(p->params, p->np, 0, 0);
        jt_scr_ed(scr, mode);
        if (mode == 3 && h && h->history_cleared) h->history_cleared(h->ctx);
        break;
    }
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
        int n = pdef(p->params, p->np, 0, 1);
        jt_buf *b = scr->active;
        b->pending_wrap = 0;
        for (int k = 0; k < n; k++) {
            int x = b->cx - 1;
            while (x > 0 && !b->tabstops[x]) x--;
            b->cx = x < 0 ? 0 : x;
            if (b->cx == 0) break;
        }
        break;
    }
    case 'b': {
        if (!scr->has_last_print) break;
        int n = pdef(p->params, p->np, 0, 1);
        uint32_t cp = scr->last_print;
        if (cp >= 0x20 && cp < 0x7F && !scr->insert_mode) {
            uint8_t buf[128];
            memset(buf, (uint8_t)cp, sizeof buf);
            while (n > 0) {
                int chunk = n < (int)sizeof buf ? n : (int)sizeof buf;
                jt_scr_print_run(scr, buf, (size_t)chunk);
                n -= chunk;
            }
        } else {
            for (int i = 0; i < n; i++) jt_scr_print_scalar(scr, cp);
        }
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
            uint16_t n = p->np > 0 ? p->params[i] : 0;
            if (n == 4) scr->insert_mode = 1;
            if (n == 20) scr->linefeed_nl = 1;
        }
        break;
    case 'l':
        for (int i = 0; i < (p->np > 0 ? p->np : 1); i++) {
            uint16_t n = p->np > 0 ? p->params[i] : 0;
            if (n == 4) scr->insert_mode = 0;
            if (n == 20) scr->linefeed_nl = 0;
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
    case 's':
        if (priv == 0 && p->ni == 0) jt_scr_decsc(scr);
        break;
    case 'u':
        if (priv == 0 && p->ni == 0) jt_scr_decrc(scr);
        break;
    case 't': {
        int kind = pdef(p->params, p->np, 0, 0);
        if (kind == 14 || kind == 16 || kind == 18) {
            if (p->np > 1) break;
            if (h && h->size_report) h->size_report(h->ctx, kind);
        } else if (kind == 22 || kind == 23) {
            if (p->np < 2) break;
            int which = (int)p->params[1];
            if (which != 0 && which != 2) break;
            if (h && h->size_report) h->size_report(h->ctx, kind);
        }
        break;
    }
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
            jt_img_abort_loading(&p->load);
            jt_scr_ris(scr);
            if (h && h->history_cleared) h->history_cleared(h->ctx);
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
    if (p->ni == 1 && p->inter[0] == '#' && final == '8') {
        jt_scr_decaln(scr);
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
    clear_seq(p);
    if (first == '?') {
        p->inter[0] = '?';
        p->ni = 1;
        j++;
        if (j >= n) return 0;
        first = bytes[j];
        if ((first >= 0x3C && first <= 0x3F) || (first >= 0x20 && first <= 0x2F))
            return 0;
    } else if ((first >= 0x3C && first <= 0x3F) || (first >= 0x20 && first <= 0x2F))
        return 0;
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

static int decode_utf8(const uint8_t *p, size_t n, uint32_t *cp, size_t *adv);
static size_t take_combining(const uint8_t *p, size_t n, uint32_t *marks, int max, int *nmarks);

/* Ghostty/xterm: C1 decoded from UTF-8 is ignored, not printed or executed. */
static int utf8_c1(uint32_t cp) {
    return cp >= 0x80 && cp <= 0x9F;
}

static void emit_utf8_run(jt_vt *p, jt_scr *scr, const uint8_t *src, size_t n) {
    if (!scr) return;
    size_t j = 0;
    while (j < n) {
        if (p->utf8_st == 0) {
            uint8_t b0 = src[j];
            if (b0 < 0x80) {
                if (b0 >= 0x20 && b0 != 0x7F) {
                    size_t ascii = jt_scan_printable_ascii(src + j, n - j);
                    if (ascii == 0) ascii = 1;
                    if (!(j + ascii < n && src[j + ascii] >= 0xC2)) {
                        jt_scr_print_run(scr, src + j, ascii);
                        j += ascii;
                        continue;
                    }
                    uint32_t marks[15];
                    int nmarks = 0;
                    size_t extra = take_combining(src + j + ascii, n - (j + ascii), marks, 15, &nmarks);
                    if (nmarks > 0) {
                        if (ascii > 1) jt_scr_print_run(scr, src + j, ascii - 1);
                        jt_scr_print_cluster(scr, src[j + ascii - 1], marks, nmarks);
                        j += ascii + extra;
                    } else {
                        jt_scr_print_run(scr, src + j, ascii);
                        j += ascii;
                    }
                    continue;
                }
                break;
            }
#if defined(__ARM_NEON)
            if ((b0 & 0xF0) == 0xE0 && j + 16 <= n) {
                uint32_t cps[5];
                if (try_neon_utf8_3(src + j, cps)) {
                    uint32_t widebuf[64];
                    int nw = 0;
                    do {
                        int a = 0;
                        while (a < 5) {
                            if (jt_codepoint_width(cps[a]) == 2) {
                                if (nw == 64) {
                                    jt_scr_print_wide_run(scr, widebuf, nw);
                                    nw = 0;
                                }
                                widebuf[nw++] = cps[a];
                            } else {
                                if (nw > 0) {
                                    jt_scr_print_wide_run(scr, widebuf, nw);
                                    nw = 0;
                                }
                                jt_scr_print_scalar(scr, cps[a]);
                            }
                            a++;
                        }
                        j += 15;
                        if (j + 16 > n) break;
                    } while (try_neon_utf8_3(src + j, cps));
                    while (j + 2 < n && (src[j] & 0xF0) == 0xE0
                           && (src[j + 1] & 0xC0) == 0x80
                           && (src[j + 2] & 0xC0) == 0x80) {
                        uint32_t cp = ((uint32_t)(src[j] & 0x0F) << 12)
                            | ((uint32_t)(src[j + 1] & 0x3F) << 6)
                            | (src[j + 2] & 0x3F);
                        int ok = (src[j] == 0xE0) ? (src[j + 1] >= 0xA0)
                            : (src[j] == 0xED) ? (src[j + 1] < 0xA0) : 1;
                        if (!ok || cp < 0x800 || jt_codepoint_width(cp) != 2) break;
                        if (nw == 64) {
                            jt_scr_print_wide_run(scr, widebuf, nw);
                            nw = 0;
                        }
                        widebuf[nw++] = cp;
                        j += 3;
                    }
                    if (nw > 0) jt_scr_print_wide_run(scr, widebuf, nw);
                    continue;
                }
            }
#endif
            if ((b0 & 0xE0) == 0xC0 && b0 >= 0xC2 && j + 1 < n) {
                uint8_t b1 = src[j + 1];
                if ((b1 & 0xC0) == 0x80) {
                    uint32_t buf[16];
                    int nb = 0;
                    size_t k = j;
                    while (nb < 16 && k + 1 < n
                           && (src[k] & 0xE0) == 0xC0 && src[k] >= 0xC2
                           && (src[k + 1] & 0xC0) == 0x80) {
                        uint32_t cp = ((uint32_t)(src[k] & 0x1F) << 6) | (src[k + 1] & 0x3F);
                        if (utf8_c1(cp) || jt_codepoint_width(cp) != 1) break;
                        buf[nb++] = cp;
                        k += 2;
                    }
                    if (nb >= 1) {
                        uint32_t marks[15];
                        int nmarks = 0;
                        size_t extra = 0;
                        if (k < n && src[k] >= 0xC2)
                            extra = take_combining(src + k, n - k, marks, 15, &nmarks);
                        if (nmarks > 0) {
                            if (nb > 1) jt_scr_print_narrow_run(scr, buf, nb - 1);
                            jt_scr_print_cluster(scr, buf[nb - 1], marks, nmarks);
                            j = k + extra;
                            continue;
                        }
                        if (nb > 1) {
                            jt_scr_print_narrow_run(scr, buf, nb);
                            j = k;
                            continue;
                        }
                    }
                    uint32_t cp = ((uint32_t)(b0 & 0x1F) << 6) | (b1 & 0x3F);
                    if (!utf8_c1(cp)) jt_scr_print_scalar(scr, cp);
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
                        uint32_t buf[8];
                        int nb = 0;
                        size_t k = j;
                        while (nb < 8 && k + 3 < n
                               && (src[k] & 0xF8) == 0xF0 && src[k] <= 0xF4
                               && (src[k + 1] & 0xC0) == 0x80
                               && (src[k + 2] & 0xC0) == 0x80
                               && (src[k + 3] & 0xC0) == 0x80) {
                            uint32_t c4 = ((uint32_t)(src[k] & 0x07) << 18)
                                | ((uint32_t)(src[k + 1] & 0x3F) << 12)
                                | ((uint32_t)(src[k + 2] & 0x3F) << 6)
                                | (src[k + 3] & 0x3F);
                            int ok4 = (src[k] == 0xF0) ? (src[k + 1] >= 0x90)
                                : (src[k] == 0xF4) ? (src[k + 1] < 0x90) : 1;
                            if (!ok4 || c4 < 0x10000 || c4 > 0x10FFFF
                                || jt_codepoint_width(c4) != 2)
                                break;
                            buf[nb++] = c4;
                            k += 4;
                        }
                        if (nb > 1) {
                            jt_scr_print_wide_run(scr, buf, nb);
                            j = k;
                            continue;
                        }
                        jt_scr_print_scalar(scr, cp);
                        j += 4;
                        continue;
                    }
                }
            }
        }
        uint32_t cp = 0;
        int r = jt_utf8_next(&p->utf8_st, &p->utf8_acc, src[j], &cp);
        if ((r == 1 || r == 2) && !utf8_c1(cp)) jt_scr_print_scalar(scr, cp);
        if (r != 2) j++;
    }
}

static void execute_c0(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t b) {
    if (b == 0x07) {
        if (p->state == JT_ST_OSC_STRING) finish_osc(p, scr, h);
        if (p->state == JT_ST_DCS_IGNORE) finish_dcs(p, scr, h);
        if (p->state == JT_ST_OSC_STRING || p->state == JT_ST_OSC_IGNORE
            || p->state == JT_ST_DCS_IGNORE) {
            enter_ground(p);
            return;
        }
        if (h && h->bell) h->bell(h->ctx);
        return;
    }
    if (b == 0x1B) {
        if (p->state == JT_ST_OSC_STRING) finish_osc(p, scr, h);
        if (p->state == JT_ST_DCS_IGNORE) finish_dcs(p, scr, h);
        if (p->state == JT_ST_APC_G) jt_apc_finish(p, scr, h);
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
        if (scr->linefeed_nl) jt_scr_cr(scr);
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

static int apc_active(const jt_vt *p) {
    return p->state == JT_ST_APC_G || p->state == JT_ST_APC_IGNORE;
}

static void apc_close(jt_vt *p, jt_scr *scr, const jt_vt_host *h, int finish) {
    p->apc_esc = 0;
    if (finish && p->state == JT_ST_APC_G) jt_apc_finish(p, scr, h);
    else {
        p->apc_n = 0;
        p->apc_ignore = 0;
        jt_img_abort_loading(&p->load);
    }
    enter_ground(p);
}

enum { JT_APC_ESC_ESC = 1, JT_APC_ESC_CSI = 2 };

static void apc_abort(jt_vt *p) {
    p->apc_esc = 0;
    p->apc_n = 0;
    p->apc_ignore = 0;
    p->apc_expect_g = 0;
    jt_img_abort_loading(&p->load);
}

static void apc_enter_private_csi(jt_vt *p) {
    apc_abort(p);
    enter_csi(p);
    p->inter[0] = '?';
    p->ni = 1;
    p->state = JT_ST_CSI_PARAM;
}

static int apc_resume_esc(
    jt_vt *p,
    jt_scr *scr,
    const jt_vt_host *h,
    const uint8_t *bytes,
    size_t *i
) {
    uint8_t st = p->apc_esc;
    p->apc_esc = 0;
    uint8_t b = bytes[*i];
    if (st == JT_APC_ESC_ESC) {
        if (b == '\\') {
            apc_close(p, scr, h, p->state == JT_ST_APC_G);
            (*i)++;
            return 1;
        }
        if (b == '_') {
            apc_abort(p);
            p->apc_expect_g = 1;
            p->state = JT_ST_SOS_PM_APC;
            (*i)++;
            return 1;
        }
        if (b == '[') {
            p->apc_esc = JT_APC_ESC_CSI;
            (*i)++;
            return 1;
        }
        if (p->state == JT_ST_APC_G) {
            uint8_t esc = 0x1B;
            jt_apc_feed(p, &esc, 1);
            if (p->apc_ignore) p->state = JT_ST_APC_IGNORE;
        }
        return 0;
    }
    if (st == JT_APC_ESC_CSI) {
        if (b == '?') {
            apc_enter_private_csi(p);
            (*i)++;
            return 1;
        }
        if (p->state == JT_ST_APC_G) {
            uint8_t pre[2] = {0x1B, '['};
            jt_apc_feed(p, pre, 2);
            if (p->apc_ignore) p->state = JT_ST_APC_IGNORE;
        }
        return 0;
    }
    return 0;
}

static int apc_take_esc(
    jt_vt *p,
    jt_scr *scr,
    const jt_vt_host *h,
    const uint8_t *bytes,
    size_t *i,
    size_t n
) {
    if (*i + 1 >= n) {
        p->apc_esc = JT_APC_ESC_ESC;
        return -1;
    }
    uint8_t n1 = bytes[*i + 1];
    if (n1 == '\\') {
        apc_close(p, scr, h, p->state == JT_ST_APC_G);
        *i += 2;
        return 1;
    }
    if (n1 == '_') {
        apc_abort(p);
        p->apc_expect_g = 1;
        p->state = JT_ST_SOS_PM_APC;
        *i += 2;
        return 1;
    }
    if (n1 == '[') {
        if (*i + 2 >= n) {
            p->apc_esc = JT_APC_ESC_CSI;
            return -1;
        }
        if (bytes[*i + 2] == '?') {
            apc_enter_private_csi(p);
            *i += 3;
            return 1;
        }
        if (p->state == JT_ST_APC_G) {
            uint8_t esc = 0x1B;
            jt_apc_feed(p, &esc, 1);
            if (p->apc_ignore) p->state = JT_ST_APC_IGNORE;
        }
        (*i)++;
        return 1;
    }
    if (p->state == JT_ST_APC_G) {
        uint8_t esc = 0x1B;
        jt_apc_feed(p, &esc, 1);
        if (p->apc_ignore) p->state = JT_ST_APC_IGNORE;
    }
    (*i)++;
    return 1;
}

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
        p->osc_n = 0;
        p->apc_expect_g = 0;
        p->state = JT_ST_SOS_PM_APC;
        break;
    case '_':
        p->osc_n = 0;
        p->apc_expect_g = 1;
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
        if (apc_active(p)) apc_close(p, scr, h, 0);
        else {
            utf8_reset(p);
            enter_ground(p);
        }
        if (b == 0x1A && scr) jt_scr_print_scalar(scr, 0xFFFD);
        return;
    }
    if (b == 0x1B) {
        if (apc_active(p)) {
            p->apc_esc = 1;
            return;
        }
        if (p->state == JT_ST_OSC_STRING) finish_osc(p, scr, h);
        if (p->state == JT_ST_DCS_IGNORE) finish_dcs(p, scr, h);
        utf8_reset(p);
        enter_escape(p);
        return;
    }
    if (b == 0x9C && (apc_active(p) || p->state == JT_ST_SOS_PM_APC)) {
        apc_close(p, scr, h, p->state == JT_ST_APC_G);
        return;
    }
    int in_string = p->state == JT_ST_OSC_STRING || p->state == JT_ST_OSC_IGNORE
        || p->state == JT_ST_SOS_PM_APC || p->state == JT_ST_DCS_IGNORE
        || p->state == JT_ST_APC_G || p->state == JT_ST_APC_IGNORE;
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
        if (p->apc_expect_g) {
            p->apc_expect_g = 0;
            if (b == 'G') {
                jt_apc_begin(p);
                p->state = JT_ST_APC_G;
                break;
            }
        }
        break;
    case JT_ST_APC_G:
        if (b < 0x20 || b >= 0x80) break;
        if (p->apc_ignore || p->apc_n >= JT_IMG_MAX_APC) {
            p->apc_ignore = 1;
            p->state = JT_ST_APC_IGNORE;
        } else {
            jt_apc_feed(p, &b, 1);
            if (p->apc_ignore) p->state = JT_ST_APC_IGNORE;
        }
        break;
    case JT_ST_APC_IGNORE:
        break;
    case JT_ST_DCS_IGNORE:
        if (b == 0x07) {
            finish_dcs(p, scr, h);
            enter_ground(p);
        } else if (p->osc_n < 4096) {
            p->osc[p->osc_n++] = b;
        }
        break;
    default:
        break;
    }
}

static int decode_utf8(const uint8_t *p, size_t n, uint32_t *cp, size_t *adv) {
    if (n == 0) return 0;
    uint8_t b0 = p[0];
    if (b0 < 0x80) {
        *cp = b0;
        *adv = 1;
        return 1;
    }
    if ((b0 & 0xE0) == 0xC0 && b0 >= 0xC2 && n >= 2 && (p[1] & 0xC0) == 0x80) {
        *cp = ((uint32_t)(b0 & 0x1F) << 6) | (p[1] & 0x3F);
        *adv = 2;
        return 1;
    }
    if ((b0 & 0xF0) == 0xE0 && n >= 3 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
        uint32_t c = ((uint32_t)(b0 & 0x0F) << 12) | ((uint32_t)(p[1] & 0x3F) << 6) | (p[2] & 0x3F);
        int ok = (b0 == 0xE0) ? (p[1] >= 0xA0) : (b0 == 0xED) ? (p[1] < 0xA0) : 1;
        if (ok && c >= 0x800) {
            *cp = c;
            *adv = 3;
            return 1;
        }
    }
    if ((b0 & 0xF8) == 0xF0 && b0 <= 0xF4 && n >= 4
        && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80 && (p[3] & 0xC0) == 0x80) {
        uint32_t c = ((uint32_t)(b0 & 0x07) << 18) | ((uint32_t)(p[1] & 0x3F) << 12)
            | ((uint32_t)(p[2] & 0x3F) << 6) | (p[3] & 0x3F);
        int ok = (b0 == 0xF0) ? (p[1] >= 0x90) : (b0 == 0xF4) ? (p[1] < 0x90) : 1;
        if (ok && c >= 0x10000 && c <= 0x10FFFF) {
            *cp = c;
            *adv = 4;
            return 1;
        }
    }
    return 0;
}

static size_t take_combining(const uint8_t *p, size_t n, uint32_t *marks, int max, int *nmarks) {
    size_t off = 0;
    *nmarks = 0;
    while (*nmarks < max) {
        uint32_t cp;
        size_t adv;
        if (!decode_utf8(p + off, n - off, &cp, &adv)) break;
        if (cp < 0x80 || jt_codepoint_width(cp) != 0) break;
        marks[(*nmarks)++] = cp;
        off += adv;
    }
    return off;
}

static int sync_ensure(jt_vt *p) {
    if (p->sync_buf) return 1;
    p->sync_buf = (uint8_t *)malloc(JT_SYNC_BUF);
    if (!p->sync_buf) return 0;
    p->sync_cap = JT_SYNC_BUF;
    p->sync_n = 0;
    return 1;
}

static void sync_apply(jt_vt *p, jt_scr *scr, const jt_vt_host *h, size_t off);
static void sync_buf_in(jt_vt *p, jt_scr *scr, const jt_vt_host *h,
                       const uint8_t *bytes, size_t n);

static void sync_apply(jt_vt *p, jt_scr *scr, const jt_vt_host *h, size_t off) {
    if (off > p->sync_n) off = p->sync_n;
    p->sync_applying = 1;
    p->syncing = 0;
    if (off > 0 && p->sync_buf)
        jt_vt_feed(p, p->sync_buf, off, scr, h);
    if (off < p->sync_n && p->sync_buf) {
        size_t tail = p->sync_n - off;
        memmove(p->sync_buf, p->sync_buf + off, tail);
        p->sync_n = tail;
        p->syncing = 1;
        jt_sync_set(scr, 1);
    } else {
        p->sync_n = 0;
        p->syncing = 0;
        jt_sync_set(scr, 0);
    }
    p->sync_applying = 0;
}

static void sync_scan(jt_vt *p, jt_scr *scr, const jt_vt_host *h, size_t new_n) {
    size_t buf_len = p->sync_n;
    size_t start = buf_len - new_n;
    if (start >= JT_SYNC_ESC - 1) start -= JT_SYNC_ESC - 1;
    else start = 0;
    size_t end = buf_len;
    if (end >= JT_SYNC_ESC - 1) end -= JT_SYNC_ESC - 1;
    else return;
    if (end <= start || !p->sync_buf) return;
    size_t bsu = (size_t)-1;
    size_t i = end;
    while (i > start) {
        i--;
        if (p->sync_buf[i] != 0x1B) continue;
        if (i + JT_SYNC_ESC > buf_len) continue;
        if (memcmp(p->sync_buf + i, JT_BSU, JT_SYNC_ESC) == 0) {
            jt_sync_set(scr, 1);
            bsu = i;
        } else if (memcmp(p->sync_buf + i, JT_ESU, JT_SYNC_ESC) == 0) {
            sync_apply(p, scr, h, bsu != (size_t)-1 ? bsu : buf_len);
            return;
        }
    }
}

static void sync_buf_in(jt_vt *p, jt_scr *scr, const jt_vt_host *h,
                       const uint8_t *bytes, size_t n) {
    if (!bytes || n == 0) return;
    if (!sync_ensure(p) || p->sync_n + n >= p->sync_cap - 1) {
        size_t held = p->sync_n;
        sync_apply(p, scr, h, held);
        jt_vt_feed(p, bytes, n, scr, h);
        return;
    }
    memcpy(p->sync_buf + p->sync_n, bytes, n);
    p->sync_n += n;
    sync_scan(p, scr, h, n);
}

size_t jt_vt_sync_bytes(const jt_vt *p) {
    return p ? p->sync_n : 0;
}

void jt_vt_sync_timeout(jt_vt *p, jt_scr *scr, const jt_vt_host *host) {
    if (!p) return;
    if (p->syncing && p->sync_n)
        sync_apply(p, scr, host, p->sync_n);
    else {
        p->syncing = 0;
        p->sync_n = 0;
        jt_sync_set(scr, 0);
    }
}

void jt_vt_sync_drop(jt_vt *p, jt_scr *scr) {
    if (!p) return;
    p->sync_n = 0;
    p->syncing = 0;
    p->sync_applying = 0;
    jt_sync_set(scr, 0);
}

void jt_vt_feed(jt_vt *p, const uint8_t *bytes, size_t n,
                jt_scr *scr, const jt_vt_host *host) {
    if (!p || !bytes || n == 0) return;
    if (p->syncing && !p->sync_applying) {
        sync_buf_in(p, scr, host, bytes, n);
        return;
    }
    size_t i = 0;
    while (i < n) {
        if (p->apc_esc) {
            if (apc_resume_esc(p, scr, host, bytes, &i)) continue;
        }
        if (p->state == JT_ST_APC_G) {
            size_t j = i;
            while (j < n && bytes[j] >= 0x20 && bytes[j] < 0x80) j++;
            if (j > i) jt_apc_feed(p, bytes + i, j - i);
            if (p->apc_ignore) p->state = JT_ST_APC_IGNORE;
            i = j;
            if (i >= n) return;
            uint8_t b = bytes[i];
            if (b == 0x1B) {
                int r = apc_take_esc(p, scr, host, bytes, &i, n);
                if (r < 0) return;
                continue;
            }
            if (b == 0x9C) {
                apc_close(p, scr, host, p->state == JT_ST_APC_G);
                i++;
                continue;
            }
            if (b == 0x18 || b == 0x1A) {
                apc_close(p, scr, host, 0);
                if (b == 0x1A && scr) jt_scr_print_scalar(scr, 0xFFFD);
            }
            i++;
            continue;
        }
        if (p->state == JT_ST_APC_IGNORE) {
            size_t j = i;
            while (j < n && bytes[j] != 0x1B && bytes[j] != 0x18 && bytes[j] != 0x1A
                   && bytes[j] != 0x9C)
                j++;
            i = j;
            if (i >= n) return;
            uint8_t b = bytes[i];
            if (b == 0x1B) {
                int r = apc_take_esc(p, scr, host, bytes, &i, n);
                if (r < 0) return;
                continue;
            }
            apc_close(p, scr, host, 0);
            if (b == 0x1A && scr) jt_scr_print_scalar(scr, 0xFFFD);
            i++;
            continue;
        }
        if (p->state == JT_ST_GROUND) {
            uint8_t b = bytes[i];
            if (b == 0x1B) {
                size_t j = i + 1;
                if (try_fast_csi(p, scr, host, bytes, &j, n)) {
                    i = j;
                    if (p->syncing && !p->sync_applying) {
                        sync_buf_in(p, scr, host, bytes + i, n - i);
                        return;
                    }
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
                    if (!(scr && rest > ascii && sp[ascii] >= 0xC2)) {
                        if (scr) jt_scr_print_run(scr, sp, ascii);
                        i += ascii;
                        continue;
                    }
                    uint32_t marks[15];
                    int nmarks = 0;
                    size_t extra = take_combining(sp + ascii, rest - ascii, marks, 15, &nmarks);
                    if (nmarks > 0) {
                        if (ascii > 1) jt_scr_print_run(scr, sp, ascii - 1);
                        jt_scr_print_cluster(scr, sp[ascii - 1], marks, nmarks);
                        i += ascii + extra;
                    } else {
                        jt_scr_print_run(scr, sp, ascii);
                        i += ascii;
                    }
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
        if (p->syncing && !p->sync_applying) {
            sync_buf_in(p, scr, host, bytes + i, n - i);
            return;
        }
    }
}
