#include "jt_vt.h"

#include <stdio.h>
#include <string.h>

static int colon_after(uint32_t seps, int i) {
    return (seps >> i) & 1;
}

static int parse_color(const uint16_t *p, int n, uint32_t seps, int i, uint32_t *out) {
    if (i + 1 >= n) return i + 1;
    int kind = (int)p[i + 1];
    int colon = colon_after(seps, i);
    if (kind == 5) {
        if (i + 2 < n) *out = color_indexed((uint8_t)p[i + 2]);
        return i + 3;
    }
    if (kind != 2) return i + 2;
    if (colon && i + 5 < n) {
        *out = color_rgb((uint8_t)p[i + 3], (uint8_t)p[i + 4], (uint8_t)p[i + 5]);
        return i + 6;
    }
    if (i + 4 < n) {
        *out = color_rgb((uint8_t)p[i + 2], (uint8_t)p[i + 3], (uint8_t)p[i + 4]);
        return i + 5;
    }
    return i + 2;
}

static void set_ul(jt_pen *pen, uint16_t style) {
    pen->attrs = (uint16_t)((pen->attrs & (uint16_t)~ATTR_UL_MASK) | (style & ATTR_UL_MASK));
}

static void reset_pen(jt_scr *s) {
    s->pen.fg = COLOR_DEFAULT;
    s->pen.bg = COLOR_DEFAULT;
    s->pen.ul_color = COLOR_DEFAULT;
    s->pen.attrs = 0;
    jt_pen_refresh_extra(s);
}

static int sgr_lit(char *buf, int cap, int o, const char *s) {
    int n = (int)strlen(s);
    if (o < 0 || o + n >= cap) return -1;
    memcpy(buf + o, s, (size_t)n);
    buf[o + n] = 0;
    return o + n;
}

static int sgr_fmt(char *buf, int cap, int o, const char *fmt, uint32_t a, uint32_t b, uint32_t c, int nargs) {
    int w;
    if (nargs == 3) w = snprintf(buf + o, (size_t)(cap - o), fmt, a, b, c);
    else if (nargs == 1) w = snprintf(buf + o, (size_t)(cap - o), fmt, a);
    else w = snprintf(buf + o, (size_t)(cap - o), "%s", fmt);
    if (w < 0 || o + w >= cap) return -1;
    return o + w;
}

static int sgr_color(char *buf, int cap, int o, int fg, uint32_t c) {
    uint32_t t = color_type(c);
    if (t == 0) return o;
    if (t == 1) {
        uint32_t idx = color_payload(c);
        if (idx >= 16)
            return sgr_fmt(buf, cap, o, fg ? ";38:5:%u" : ";48:5:%u", idx, 0, 0, 1);
        if (idx >= 8)
            return sgr_fmt(buf, cap, o, fg ? ";9%u" : ";10%u", idx - 8, 0, 0, 1);
        return sgr_fmt(buf, cap, o, fg ? ";3%u" : ";4%u", idx, 0, 0, 1);
    }
    if (t == 2) {
        uint32_t p = color_payload(c);
        return sgr_fmt(buf, cap, o, fg ? ";38:2::%u:%u:%u" : ";48:2::%u:%u:%u",
                       p >> 16, (p >> 8) & 255u, p & 255u, 3);
    }
    return o;
}

int jt_sgr_encode(const jt_scr *s, char *buf, int cap) {
    if (!s || !buf || cap < 2) return -1;
    int o = sgr_lit(buf, cap, 0, "0");
    if (o < 0) return -1;
    uint16_t a = s->pen.attrs;
    if (a & ATTR_BOLD) { o = sgr_lit(buf, cap, o, ";1"); if (o < 0) return -1; }
    if (a & ATTR_DIM) { o = sgr_lit(buf, cap, o, ";2"); if (o < 0) return -1; }
    if (a & ATTR_ITALIC) { o = sgr_lit(buf, cap, o, ";3"); if (o < 0) return -1; }
    uint16_t ul = (uint16_t)(a & ATTR_UL_MASK);
    if (ul == UL_SINGLE) { o = sgr_lit(buf, cap, o, ";4"); if (o < 0) return -1; }
    else if (ul == UL_DOUBLE) { o = sgr_lit(buf, cap, o, ";4:2"); if (o < 0) return -1; }
    else if (ul == UL_CURLY) { o = sgr_lit(buf, cap, o, ";4:3"); if (o < 0) return -1; }
    else if (ul == UL_DOTTED) { o = sgr_lit(buf, cap, o, ";4:4"); if (o < 0) return -1; }
    else if (ul == UL_DASHED) { o = sgr_lit(buf, cap, o, ";4:5"); if (o < 0) return -1; }
    if (a & ATTR_OVERLINE) { o = sgr_lit(buf, cap, o, ";53"); if (o < 0) return -1; }
    if (a & ATTR_BLINK) { o = sgr_lit(buf, cap, o, ";5"); if (o < 0) return -1; }
    if (a & ATTR_REVERSE) { o = sgr_lit(buf, cap, o, ";7"); if (o < 0) return -1; }
    if (a & ATTR_HIDDEN) { o = sgr_lit(buf, cap, o, ";8"); if (o < 0) return -1; }
    if (a & ATTR_STRIKETHROUGH) { o = sgr_lit(buf, cap, o, ";9"); if (o < 0) return -1; }
    o = sgr_color(buf, cap, o, 1, s->pen.fg);
    if (o < 0) return -1;
    return sgr_color(buf, cap, o, 0, s->pen.bg);
}

void jt_sgr_apply(jt_scr *s, const uint16_t *p, int n, uint32_t seps) {
    if (!s) return;
    if (n <= 0) {
        reset_pen(s);
        return;
    }
    int i = 0;
    while (i < n) {
        uint16_t v = p[i];
        int colon = colon_after(seps, i);
        switch (v) {
        case 0:
            reset_pen(s);
            break;
        case 1:
            s->pen.attrs |= ATTR_BOLD;
            break;
        case 2:
            s->pen.attrs |= ATTR_DIM;
            break;
        case 3:
            s->pen.attrs |= ATTR_ITALIC;
            break;
        case 4:
            if (colon && i + 1 < n) {
                uint16_t st = p[i + 1];
                uint16_t ul = UL_SINGLE;
                if (st == 0) ul = UL_NONE;
                else if (st == 1) ul = UL_SINGLE;
                else if (st == 2) ul = UL_DOUBLE;
                else if (st == 3) ul = UL_CURLY;
                else if (st == 4) ul = UL_DOTTED;
                else if (st == 5) ul = UL_DASHED;
                set_ul(&s->pen, ul);
                i++;
            } else {
                set_ul(&s->pen, UL_SINGLE);
            }
            break;
        case 5:
        case 6:
            s->pen.attrs |= ATTR_BLINK;
            break;
        case 7:
            s->pen.attrs |= ATTR_REVERSE;
            break;
        case 8:
            s->pen.attrs |= ATTR_HIDDEN;
            break;
        case 9:
            s->pen.attrs |= ATTR_STRIKETHROUGH;
            break;
        case 21:
            set_ul(&s->pen, UL_DOUBLE);
            break;
        case 22:
            s->pen.attrs = (uint16_t)(s->pen.attrs & (uint16_t)~(ATTR_BOLD | ATTR_DIM));
            break;
        case 23:
            s->pen.attrs = (uint16_t)(s->pen.attrs & (uint16_t)~ATTR_ITALIC);
            break;
        case 24:
            set_ul(&s->pen, UL_NONE);
            break;
        case 25:
            s->pen.attrs = (uint16_t)(s->pen.attrs & (uint16_t)~ATTR_BLINK);
            break;
        case 27:
            s->pen.attrs = (uint16_t)(s->pen.attrs & (uint16_t)~ATTR_REVERSE);
            break;
        case 28:
            s->pen.attrs = (uint16_t)(s->pen.attrs & (uint16_t)~ATTR_HIDDEN);
            break;
        case 29:
            s->pen.attrs = (uint16_t)(s->pen.attrs & (uint16_t)~ATTR_STRIKETHROUGH);
            break;
        case 38: {
            uint32_t c = s->pen.fg;
            i = parse_color(p, n, seps, i, &c) - 1;
            s->pen.fg = c;
            break;
        }
        case 48: {
            uint32_t c = s->pen.bg;
            i = parse_color(p, n, seps, i, &c) - 1;
            s->pen.bg = c;
            break;
        }
        case 58: {
            uint32_t c = s->pen.ul_color;
            i = parse_color(p, n, seps, i, &c) - 1;
            s->pen.ul_color = c;
            jt_pen_refresh_extra(s);
            break;
        }
        case 39:
            s->pen.fg = COLOR_DEFAULT;
            break;
        case 49:
            s->pen.bg = COLOR_DEFAULT;
            break;
        case 59:
            s->pen.ul_color = COLOR_DEFAULT;
            jt_pen_refresh_extra(s);
            break;
        case 53:
            s->pen.attrs |= ATTR_OVERLINE;
            break;
        case 55:
            s->pen.attrs = (uint16_t)(s->pen.attrs & (uint16_t)~ATTR_OVERLINE);
            break;
        default:
            if (v >= 30 && v <= 37)
                s->pen.fg = color_indexed((uint8_t)(v - 30));
            else if (v >= 40 && v <= 47)
                s->pen.bg = color_indexed((uint8_t)(v - 40));
            else if (v >= 90 && v <= 97)
                s->pen.fg = color_indexed((uint8_t)(8 + (v - 90)));
            else if (v >= 100 && v <= 107)
                s->pen.bg = color_indexed((uint8_t)(8 + (v - 100)));
            break;
        }
        i++;
    }
}
