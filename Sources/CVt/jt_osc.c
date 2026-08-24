#include "jt_vt.h"

#include <stdio.h>
#include <string.h>

static int is_digit(uint8_t b) { return b >= '0' && b <= '9'; }

static int parse_num(const uint8_t *p, int n, int *i, uint32_t *out) {
    if (*i >= n || !is_digit(p[*i])) return 0;
    uint32_t v = 0;
    while (*i < n && is_digit(p[*i])) {
        v = v * 10 + (uint32_t)(p[*i] - '0');
        (*i)++;
    }
    *out = v;
    return 1;
}

static int hex_nibble(uint8_t b) {
    if (b >= '0' && b <= '9') return b - '0';
    if (b >= 'a' && b <= 'f') return b - 'a' + 10;
    if (b >= 'A' && b <= 'F') return b - 'A' + 10;
    return -1;
}

static int parse_hex_bytes(const uint8_t *p, int n, int *i, int digits, uint8_t *out) {
    int acc = 0;
    for (int k = 0; k < digits; k++) {
        if (*i >= n) return 0;
        int h = hex_nibble(p[*i]);
        if (h < 0) return 0;
        acc = (acc << 4) | h;
        (*i)++;
    }
    if (digits <= 2) *out = (uint8_t)acc;
    else *out = (uint8_t)(acc >> ((digits - 2) * 4));
    return 1;
}

/* rgb:RR/GG/BB, rgb:RRRR/GGGG/BBBB, or #RRGGBB. Returns 1 and COLOR_RGB. */
static int parse_color(const uint8_t *p, int n, int *i, uint32_t *out) {
    while (*i < n && p[*i] == ' ') (*i)++;
    if (*i >= n) return 0;
    if (p[*i] == '#') {
        (*i)++;
        uint8_t r, g, b;
        if (!parse_hex_bytes(p, n, i, 2, &r)) return 0;
        if (!parse_hex_bytes(p, n, i, 2, &g)) return 0;
        if (!parse_hex_bytes(p, n, i, 2, &b)) return 0;
        *out = color_rgb(r, g, b);
        return 1;
    }
    if (*i + 4 <= n && p[*i] == 'r' && p[*i + 1] == 'g' && p[*i + 2] == 'b' && p[*i + 3] == ':') {
        *i += 4;
        int start = *i;
        int slashes = 0;
        int run = 0;
        while (start + run < n && p[start + run] != ';' && p[start + run] != '/') run++;
        int digits = run;
        if (digits != 2 && digits != 4) return 0;
        uint8_t r, g, b;
        if (!parse_hex_bytes(p, n, i, digits, &r)) return 0;
        if (*i >= n || p[*i] != '/') return 0;
        (*i)++;
        slashes++;
        if (!parse_hex_bytes(p, n, i, digits, &g)) return 0;
        if (*i >= n || p[*i] != '/') return 0;
        (*i)++;
        slashes++;
        if (!parse_hex_bytes(p, n, i, digits, &b)) return 0;
        *out = color_rgb(r, g, b);
        (void)slashes;
        return 1;
    }
    return 0;
}

static void skip_to_semi(const uint8_t *p, int n, int *i) {
    while (*i < n && p[*i] != ';') (*i)++;
}

static uint32_t color_rgb8(uint32_t packed) {
    if (color_type(packed) == 2) return packed & COLOR_PAYLOAD;
    return packed & 0xFFFFFFu;
}

static void reply_rgb(const jt_vt_host *h, const char *prefix, uint32_t packed) {
    if (!h || !h->write_pty) return;
    uint32_t rgb = color_rgb8(packed);
    uint8_t r = (uint8_t)((rgb >> 16) & 0xFF);
    uint8_t g = (uint8_t)((rgb >> 8) & 0xFF);
    uint8_t b = (uint8_t)(rgb & 0xFF);
    char buf[96];
    int n = snprintf(
        buf, sizeof buf,
        "%srgb:%02X%02X/%02X%02X/%02X%02X\033\\",
        prefix, r, r, g, g, b, b
    );
    if (n > 0) h->write_pty(h->ctx, (const uint8_t *)buf, (size_t)n);
}

static int title_ok(uint32_t cp) {
    if (cp < 0x20 || (cp >= 0x7F && cp < 0xA0)) return 0;
    if (cp >= 0x202A && cp <= 0x2069) return 0;
    return 1;
}

static void osc_title(const jt_vt_host *h, const uint8_t *p, int n) {
    if (!h || !h->set_title) return;
    uint8_t out[1024];
    int o = 0;
    uint8_t st = 0;
    uint32_t acc = 0;
    for (int i = 0; i < n && o < 1024; i++) {
        uint32_t cp = 0;
        int r = jt_utf8_next(&st, &acc, p[i], &cp);
        if (r != 1 && r != 2) continue;
        if (!title_ok(cp)) continue;
        if (cp < 0x80) {
            out[o++] = (uint8_t)cp;
        } else if (cp < 0x800) {
            if (o + 2 > 1024) break;
            out[o++] = (uint8_t)(0xC0 | (cp >> 6));
            out[o++] = (uint8_t)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            if (o + 3 > 1024) break;
            out[o++] = (uint8_t)(0xE0 | (cp >> 12));
            out[o++] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (uint8_t)(0x80 | (cp & 0x3F));
        } else {
            if (o + 4 > 1024) break;
            out[o++] = (uint8_t)(0xF0 | (cp >> 18));
            out[o++] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
            out[o++] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (uint8_t)(0x80 | (cp & 0x3F));
        }
    }
    h->set_title(h->ctx, out, (size_t)o);
}

static int utf8_sanitize(const uint8_t *p, int n, uint8_t *out, int cap) {
    int o = 0;
    uint8_t st = 0;
    uint32_t acc = 0;
    for (int i = 0; i < n && o < cap; i++) {
        uint32_t cp = 0;
        int r = jt_utf8_next(&st, &acc, p[i], &cp);
        if (r != 1 && r != 2) continue;
        if (!title_ok(cp)) continue;
        if (cp < 0x80) {
            out[o++] = (uint8_t)cp;
        } else if (cp < 0x800) {
            if (o + 2 > cap) break;
            out[o++] = (uint8_t)(0xC0 | (cp >> 6));
            out[o++] = (uint8_t)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            if (o + 3 > cap) break;
            out[o++] = (uint8_t)(0xE0 | (cp >> 12));
            out[o++] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (uint8_t)(0x80 | (cp & 0x3F));
        } else {
            if (o + 4 > cap) break;
            out[o++] = (uint8_t)(0xF0 | (cp >> 18));
            out[o++] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
            out[o++] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (uint8_t)(0x80 | (cp & 0x3F));
        }
    }
    return o;
}

static int conemu_cmd(const uint8_t *p, int n, int i, uint8_t digit) {
    if (i >= n || p[i] != digit) return 0;
    if (i + 1 >= n) return 1;
    return p[i + 1] == ';';
}

static void osc9(const jt_vt_host *h, const uint8_t *p, int n, int i) {
    if (!h) return;
    /* OSC 9;4;<0-4> optionally ;pct. Else iTerm2 notify. */
    if (i + 2 < n && p[i] == '4' && p[i + 1] == ';' && p[i + 2] >= '0' && p[i + 2] <= '4') {
        uint8_t st = (uint8_t)(p[i + 2] - '0');
        /* Omitted percent: set is 0, else 255. Remove/indeterminate ignore ;pct. */
        uint8_t pct8 = st == 1 ? 0 : 255;
        int j = i + 3;
        if ((st == 1 || st == 2 || st == 4) && j < n && p[j] == ';') {
            j++;
            uint32_t pct = 0;
            int k = j;
            if (!parse_num(p, n, &k, &pct) || k != n) {
                pct8 = 255;
            } else if (pct > 100) {
                pct8 = 100;
            } else {
                pct8 = (uint8_t)pct;
            }
        }
        if (h->progress) h->progress(h->ctx, st, pct8);
        return;
    }
    if (conemu_cmd(p, n, i, '1') || conemu_cmd(p, n, i, '2')) return;
    if (!h->notify) return;
    uint8_t body[1024];
    int nb = utf8_sanitize(p + i, n - i, body, 1024);
    if (nb <= 0) return;
    static const uint8_t title[] = "jetty";
    h->notify(h->ctx, title, 5, body, (size_t)nb);
}

static void osc777(const jt_vt_host *h, const uint8_t *p, int n, int i) {
    if (!h || !h->notify) return;
    if (i + 7 > n || memcmp(p + i, "notify;", 7) != 0) return;
    i += 7;
    int t0 = i;
    while (i < n && p[i] != ';') i++;
    uint8_t title[256];
    int nt = utf8_sanitize(p + t0, i - t0, title, 256);
    if (i < n && p[i] == ';') i++;
    uint8_t body[1024];
    int nb = utf8_sanitize(p + i, n - i, body, 1024);
    if (nt <= 0 && nb <= 0) return;
    if (nt <= 0) {
        memcpy(title, "jetty", 5);
        nt = 5;
    }
    h->notify(h->ctx, title, (size_t)nt, body, (size_t)nb);
}

static void osc4(jt_scr *s, const jt_vt_host *h, const uint8_t *p, int n, int i) {
    if (!s) return;
    while (i < n) {
        if (p[i] == ';') i++;
        uint32_t idx = 0;
        if (!parse_num(p, n, &i, &idx)) break;
        if (i >= n || p[i] != ';') break;
        i++;
        if (i < n && p[i] == '?') {
            i++;
            if (idx < 256) {
                char pre[24];
                snprintf(pre, sizeof pre, "\033]4;%u;", (unsigned)idx);
                reply_rgb(h, pre, s->palette[idx]);
            }
            continue;
        }
        uint32_t c = 0;
        if (parse_color(p, n, &i, &c) && idx < 256) {
            s->palette[idx] = c & COLOR_PAYLOAD;
            if (h && h->palette_changed) h->palette_changed(h->ctx);
        } else {
            skip_to_semi(p, n, &i);
        }
    }
}

static uint32_t *osc_color_slot(jt_scr *s, uint32_t which) {
    if (!s) return NULL;
    if (which == 10) return &s->default_fg;
    if (which == 11) return &s->default_bg;
    if (which == 12) return &s->cursor_color;
    return NULL;
}

static void osc_dynamic(jt_scr *s, const jt_vt_host *h, uint32_t which,
                        const uint8_t *p, int n, int i) {
    uint32_t *slot = osc_color_slot(s, which);
    if (!slot) return;
    if (i < n && p[i] == ';') i++;
    if (i < n && p[i] == '?') {
        uint32_t c = *slot;
        if (which == 12 && color_type(c) != 2) c = s->default_fg;
        char pre[16];
        snprintf(pre, sizeof pre, "\033]%u;", (unsigned)which);
        reply_rgb(h, pre, c);
        return;
    }
    uint32_t c = 0;
    if (parse_color(p, n, &i, &c)) {
        *slot = c;
        if (h && h->palette_changed) h->palette_changed(h->ctx);
    }
}

static void osc52(const jt_vt_host *h, const uint8_t *p, int n, int i) {
    if (!h) return;
    if (i < n && p[i] == ';') i++;
    uint8_t kind = 'c';
    if (i < n && p[i] != ';') {
        kind = p[i];
        if (kind != 'c' && kind != 'p' && kind != 's') kind = 'c';
        while (i < n && p[i] != ';') i++;
    }
    if (i < n && p[i] == ';') i++;
    if (i < n && p[i] == '?') {
        if (h->osc52_read) h->osc52_read(h->ctx, kind);
        return;
    }
    if (h->osc52_write) h->osc52_write(h->ctx, kind, p + i, (size_t)(n - i));
}

void jt_osc_dispatch(jt_scr *s, const jt_vt_host *h, const uint8_t *p, int n) {
    if (!p || n <= 0) return;
    int i = 0;
    uint32_t cmd = 0;
    if (!parse_num(p, n, &i, &cmd)) return;
    if (i < n && p[i] == ';') i++;
    switch (cmd) {
    case 0:
    case 2:
        osc_title(h, p + i, n - i);
        break;
    case 4:
        osc4(s, h, p, n, i);
        break;
    case 10:
    case 11:
    case 12:
        osc_dynamic(s, h, cmd, p, n, i);
        break;
    case 7:
        if (h && h->osc7) h->osc7(h->ctx, p + i, (size_t)(n - i));
        break;
    case 8: {
        if (!s) break;
        int split = i;
        while (split < n && p[split] != ';') split++;
        const uint8_t *kv = p + i;
        int kn = split - i;
        const char *uri = "";
        char uribuf[4096];
        uribuf[0] = 0;
        if (split < n) {
            int un = n - split - 1;
            if (un > 4095) un = 4095;
            memcpy(uribuf, p + split + 1, (size_t)un);
            uribuf[un] = 0;
            uri = uribuf;
        }
        char idbuf[256];
        idbuf[0] = 0;
        int k = 0;
        while (k < kn) {
            int eq = k;
            while (eq < kn && kv[eq] != '=' && kv[eq] != ':') eq++;
            int vend = eq;
            while (vend < kn && kv[vend] != ':') vend++;
            if (eq < kn && kv[eq] == '=' && eq - k == 2 && kv[k] == 'i' && kv[k + 1] == 'd') {
                int vs = eq + 1;
                int vl = vend - vs;
                if (vl > 255) vl = 255;
                memcpy(idbuf, kv + vs, (size_t)vl);
                idbuf[vl] = 0;
            }
            k = vend + 1;
        }
        if (!uri[0] && !idbuf[0]) jt_scr_set_osc8(s, NULL, NULL);
        else jt_scr_set_osc8(s, idbuf[0] ? idbuf : NULL, uri);
        break;
    }
    case 9:
        osc9(h, p, n, i);
        break;
    case 52:
        osc52(h, p, n, i);
        break;
    case 133:
        if (h && h->osc133 && i < n)
            h->osc133(h->ctx, p[i], p + i, (size_t)(n - i));
        break;
    case 777:
        osc777(h, p, n, i);
        break;
    case 104:
        if (s) {
            jt_scr_palette_reset(s);
            if (h && h->palette_changed) h->palette_changed(h->ctx);
        }
        break;
    case 110:
        if (s) {
            s->default_fg = COLOR_RGB | 0xCCCCCCu;
            if (h && h->palette_changed) h->palette_changed(h->ctx);
        }
        break;
    case 111:
        if (s) {
            s->default_bg = COLOR_RGB | 0x000000u;
            if (h && h->palette_changed) h->palette_changed(h->ctx);
        }
        break;
    case 112:
        if (s) {
            s->cursor_color = COLOR_DEFAULT;
            if (h && h->palette_changed) h->palette_changed(h->ctx);
        }
        break;
    default:
        break;
    }
}
