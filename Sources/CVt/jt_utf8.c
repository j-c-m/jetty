#include "jt_vt_int.h"

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

/* Hoehrmann DFA (MIT). Same tables as linux16term l16_vt.c / Ghostty UTF8Decoder.zig. */
static const uint8_t k_utf8_cls[256] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,  2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3, 11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8,
};
static const uint8_t k_utf8_tr[] = {
    0,12,24,36,60,96,84,12,12,12,48,72, 12,12,12,12,12,12,12,12,12,12,12,12,
    12, 0,12,12,12,12,12, 0,12, 0,12,12, 12,24,12,12,12,12,12,24,12,24,12,12,
    12,12,12,12,12,12,12,24,12,12,12,12, 12,24,12,12,12,12,12,12,12,24,12,12,
    12,12,12,12,12,12,12,36,12,36,12,12, 12,36,12,12,12,12,12,36,12,36,12,12,
    12,36,12,12,12,12,12,12,12,12,12,12,
};

int jt_utf8_next(uint8_t *st, uint32_t *acc, uint8_t b, uint32_t *out) {
    uint8_t cls = k_utf8_cls[b];
    uint8_t initial = *st;
    if (*st != 0) *acc = (*acc << 6) | (uint32_t)(b & 0x3F);
    else *acc = ((uint32_t)0xFF >> cls) & (uint32_t)b;
    *st = k_utf8_tr[*st + cls];
    if (*st == 0) {
        *out = *acc;
        *acc = 0;
        return 1;
    }
    if (*st == 12) {
        *acc = 0;
        *st = 0;
        *out = 0xFFFD;
        return initial == 0 ? 1 : 2;
    }
    *out = 0;
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
size_t take_combining(const uint8_t *p, size_t n, uint32_t *marks, int max, int *nmarks);

/* Ghostty/xterm: C1 decoded from UTF-8 is ignored, not printed or executed. */
static int utf8_c1(uint32_t cp) {
    return cp >= 0x80 && cp <= 0x9F;
}

void emit_utf8_run(jt_vt *p, jt_scr *scr, const uint8_t *src, size_t n) {
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

size_t take_combining(const uint8_t *p, size_t n, uint32_t *marks, int max, int *nmarks) {
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
