/* DCS: XTGETTCAP (+q) and DECRQSS ($q). */
#include "jt_vt_int.h"

#include <stdio.h>
#include <string.h>

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

void finish_dcs(jt_vt *p, jt_scr *scr, const jt_vt_host *h) {
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
        } else if (qn == 1 && q[0] == 's') {
            if (scr->lr_margin) {
                int left = scr->active->scroll_left + 1;
                int right = scr->active->scroll_right + 1;
                w = snprintf(buf, sizeof buf, "\033P1$r%d;%ds\033\\", left, right);
            } else {
                w = snprintf(buf, sizeof buf, "\033P0$r\033\\");
            }
        } else if (qn == 2 && q[0] == ' ' && q[1] == 'q') {
            w = snprintf(buf, sizeof buf, "\033P1$r%d q\033\\", (int)scr->cursor_style);
        } else {
            w = snprintf(buf, sizeof buf, "\033P0$r\033\\");
        }
        if (w > 0) h->write_pty(h->ctx, (const uint8_t *)buf, (size_t)w);
    }
}
