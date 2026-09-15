/* CSI parameter machine and dispatch. */
#include "jt_vt_int.h"

#include <stdio.h>
#include <string.h>

static int is_da1(const jt_vt *p, uint8_t priv) {
    if (priv != 0) return 0;
    if (p->np <= 0) return 1;
    return p->np == 1 && p->params[0] == 0;
}

void start_param(jt_vt *p, uint8_t b) {
    p->param_acc = (uint32_t)(b - '0');
    p->param_empty = 0;
}

void accum_param(jt_vt *p, uint8_t b) {
    if (p->param_empty) {
        start_param(p, b);
        return;
    }
    uint32_t v = p->param_acc * 10 + (uint32_t)(b - '0');
    p->param_acc = v > 65535 ? 65535 : v;
}

void push_param(jt_vt *p, int colon) {
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
    case 67: on = s && s->backarrow; break;
    case 69: on = s && s->lr_margin; break;
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
    case 1016: on = s && s->mouse_sgr_pixels; break;
    case 1034: on = 0; break;
    case 1036: on = !s || s->alt_esc; break;
    case 1039: on = !s || s->alt_sends_escape; break;
    case 2004: on = s && s->bracketed_paste; break;
    case 5522:
        if (!s || !s->osc52_read_ask) { known = 0; break; }
        on = s->paste_events;
        break;
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
            if (final == 'c' && is_da1(p, priv)) write_str(h, "\033[?1;2c");
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
                case 67: scr->backarrow = (uint8_t)set; break;
                case 69:
                    scr->lr_margin = (uint8_t)set;
                    if (!set) {
                        int32_t r = scr->cols > 0 ? scr->cols - 1 : 0;
                        scr->primary.scroll_left = 0;
                        scr->primary.scroll_right = r;
                        scr->alt.scroll_left = 0;
                        scr->alt.scroll_right = r;
                    }
                    break;
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
                case 1004:
                    scr->focus_event = (uint8_t)set;
                    break;
                case 1006:
                    scr->mouse_sgr = (uint8_t)set;
                    if (set) scr->mouse_sgr_pixels = 0;
                    break;
                case 1007: scr->mouse_alt_scroll = (uint8_t)set; break;
                case 1016:
                    scr->mouse_sgr_pixels = (uint8_t)set;
                    if (set) scr->mouse_sgr = 0;
                    break;
                case 1036: scr->alt_esc = (uint8_t)set; break;
                case 1039: scr->alt_sends_escape = (uint8_t)set; break;
                case 1045: scr->reverse_wrap_ext = (uint8_t)set; break;
                case 1048:
                    if (set) jt_scr_decsc(scr);
                    else jt_scr_decrc(scr);
                    break;
                case 2004: scr->bracketed_paste = (uint8_t)set; break;
                case 5522:
                    if (set) {
                        if (scr->osc52_read_ask) scr->paste_events = 1;
                    } else {
                        scr->paste_events = 0;
                    }
                    break;
                case 2026:
                    if (p->sync_applying) break;
                    if (set) {
                        jt_sync_set(scr, 1);
                        p->syncing = 1;
                    } else {
                        if (p->sync_n) sync_apply(p, scr, h, p->sync_n);
                        else {
                            p->syncing = 0;
                            p->sync_n = 0;
                            jt_sync_set(scr, 0);
                        }
                    }
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
        else if (final == 'm') {
            uint16_t pp = p->np > 0 ? p->params[0] : 0;
            if (pp == 0) {
                scr->modify_other_keys = 0;
            } else if (pp == 4) {
                uint16_t pv = p->np > 1 ? p->params[1] : 0;
                if (pv == 2) scr->modify_other_keys = 2;
                else if (pv == 1) scr->modify_other_keys = 1;
                else scr->modify_other_keys = 0;
            }
        }
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
        {
            int maxx = scr->cols - 1;
            if (scr->origin_mode && scr->lr_margin) maxx = scr->active->scroll_right;
            if (scr->active->cx > maxx) scr->active->cx = maxx;
        }
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
        {
            int x0 = 0, x1 = scr->cols - 1;
            if (scr->origin_mode && scr->lr_margin) {
                x0 = scr->active->scroll_left;
                x1 = scr->active->scroll_right;
            }
            int x = x0 + pdef(p->params, p->np, 0, 1) - 1;
            if (x < x0) x = x0;
            if (x > x1) x = x1;
            scr->active->cx = x;
        }
        break;
    case 'H':
    case 'f':
        jt_scr_cup(scr, pdef(p->params, p->np, 0, 1) - 1, pdef(p->params, p->np, 1, 1) - 1);
        break;
    case 'd': {
        jt_buf *b = scr->active;
        b->pending_wrap = 0;
        int y0 = 0, y1 = scr->rows - 1;
        if (scr->origin_mode) {
            y0 = b->scroll_top;
            y1 = b->scroll_bottom;
        }
        int y = y0 + pdef(p->params, p->np, 0, 1) - 1;
        if (y < y0) y = y0;
        if (y > y1) y = y1;
        b->cy = y;
        break;
    }
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
        int left = scr->lr_margin ? b->scroll_left : 0;
        for (int k = 0; k < n; k++) {
            int x = b->cx - 1;
            while (x > left && !b->tabstops[x]) x--;
            b->cx = x < left ? left : x;
            if (b->cx == left) break;
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
        if (is_da1(p, priv)) write_str(h, "\033[?1;2c");
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
            if (n >= 0 && n <= 6) {
                scr->cursor_style = (uint8_t)n;
                scr->cursor_hollow = 0;
            }
        }
        break;
    case 's':
        if (priv == 0 && p->ni == 0) {
            if (scr->lr_margin) {
                int left = pdef(p->params, p->np, 0, 1) - 1;
                int right = (p->np < 2 || p->params[1] == 0) ? scr->cols - 1 : (int)p->params[1] - 1;
                jt_scr_decslrm(scr, left, right);
            } else if (p->np == 0) {
                jt_scr_decsc(scr);
            }
        }
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
void finish_csi(jt_vt *p, jt_scr *scr, const jt_vt_host *h, uint8_t final) {
    handle_csi(p, scr, h, final);
    enter_ground(p);
}

int try_fast_csi(jt_vt *p, jt_scr *scr, const jt_vt_host *h,
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
