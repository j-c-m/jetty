#include "jt_vt_int.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

void clear_seq(jt_vt *p) {
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

/* OSC */
void finish_osc(jt_vt *p, jt_scr *scr, const jt_vt_host *h) {
    if (p->osc_n > 0) jt_osc_dispatch(scr, h, p->osc, p->osc_n);
    p->osc_n = 0;
}

/* parser state */
void enter_ground(jt_vt *p) {
    p->state = JT_ST_GROUND;
    clear_seq(p);
    p->osc_n = 0;
    p->apc_esc = 0;
}

void enter_escape(jt_vt *p) {
    clear_seq(p);
    p->state = JT_ST_ESCAPE;
}

void enter_csi(jt_vt *p) {
    clear_seq(p);
    p->state = JT_ST_CSI_ENTRY;
}

void utf8_reset(jt_vt *p) {
    p->utf8_acc = 0;
    p->utf8_st = 0;
}

void write_str(const jt_vt_host *h, const char *s) {
    if (!h || !h->write_pty || !s) return;
    size_t n = strlen(s);
    h->write_pty(h->ctx, (const uint8_t *)s, n);
}

/* ESC */
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
            if (!p->sync_applying) {
                p->sync_n = 0;
                p->syncing = 0;
            }
            jt_scr_ris(scr);
            if (h && h->history_cleared) h->history_cleared(h->ctx);
            if (h && h->mouse_shape) {
                static const uint8_t def[] = "default";
                h->mouse_shape(h->ctx, def, 7);
            }
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

/* C0 / charset */
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

/* APC string */
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

/* byte dispatch */
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
        } else if (p->osc_n >= JT_OSC_CAP) p->state = JT_ST_OSC_IGNORE;
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
        } else if (p->osc_n < JT_OSC_CAP) {
            p->osc[p->osc_n++] = b;
        }
        break;
    default:
        break;
    }
}

/* ground + feed */
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
