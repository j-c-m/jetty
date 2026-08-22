#include "jt_vt.h"

#if defined(__ARM_NEON)
#include <arm_neon.h>

static size_t first_zero_u8x16(uint8x16_t ok) {
    uint8_t tmp[16];
    vst1q_u8(tmp, ok);
    for (int k = 0; k < 16; k++) {
        if (tmp[k] == 0) return (size_t)k;
    }
    return 16;
}

static size_t first_ff_u8x16(uint8x16_t hit) {
    uint8_t tmp[16];
    vst1q_u8(tmp, hit);
    for (int k = 0; k < 16; k++) {
        if (tmp[k]) return (size_t)k;
    }
    return 16;
}

size_t jt_scan_printable_ascii(const uint8_t *p, size_t n) {
    size_t off = 0;
    const uint8x16_t lo = vdupq_n_u8(0x20);
    const uint8x16_t span = vdupq_n_u8(0x5E);
    const uint8x16_t all = vdupq_n_u8(0xFF);
    while (off + 16 <= n) {
        uint8x16_t v = vld1q_u8(p + off);
        uint8x16_t ok = vcleq_u8(vsubq_u8(v, lo), span);
        uint64x2_t u = vreinterpretq_u64_u8(veorq_u8(ok, all));
        if (vgetq_lane_u64(u, 0) | vgetq_lane_u64(u, 1)) {
            return off + first_zero_u8x16(ok);
        }
        off += 16;
    }
    while (off < n) {
        uint8_t c = p[off];
        if (c < 0x20 || c > 0x7E) return off;
        off++;
    }
    return n;
}

size_t jt_scan_until_c0(const uint8_t *p, size_t n) {
    size_t off = 0;
    const uint8x16_t lim = vdupq_n_u8(0x20);
    const uint8x16_t del = vdupq_n_u8(0x7F);
    while (off + 16 <= n) {
        uint8x16_t v = vld1q_u8(p + off);
        uint8x16_t stop = vorrq_u8(vcltq_u8(v, lim), vceqq_u8(v, del));
        uint64x2_t u = vreinterpretq_u64_u8(stop);
        if (vgetq_lane_u64(u, 0) | vgetq_lane_u64(u, 1)) {
            return off + first_ff_u8x16(stop);
        }
        off += 16;
    }
    while (off < n) {
        uint8_t c = p[off];
        if (c < 0x20 || c == 0x7F) return off;
        off++;
    }
    return n;
}

size_t jt_scan_first_esc(const uint8_t *p, size_t n) {
    size_t off = 0;
    const uint8x16_t needle = vdupq_n_u8(0x1B);
    while (off + 16 <= n) {
        uint8x16_t v = vld1q_u8(p + off);
        uint8x16_t hit = vceqq_u8(v, needle);
        uint64x2_t u = vreinterpretq_u64_u8(hit);
        if (vgetq_lane_u64(u, 0) | vgetq_lane_u64(u, 1)) {
            return off + first_ff_u8x16(hit);
        }
        off += 16;
    }
    while (off < n) {
        if (p[off] == 0x1B) return off;
        off++;
    }
    return n;
}

#else

size_t jt_scan_printable_ascii(const uint8_t *p, size_t n) {
    size_t off = 0;
    while (off < n) {
        uint8_t c = p[off];
        if (c < 0x20 || c > 0x7E) return off;
        off++;
    }
    return n;
}

size_t jt_scan_until_c0(const uint8_t *p, size_t n) {
    size_t off = 0;
    while (off < n) {
        uint8_t c = p[off];
        if (c < 0x20 || c == 0x7F) return off;
        off++;
    }
    return n;
}

size_t jt_scan_first_esc(const uint8_t *p, size_t n) {
    size_t off = 0;
    while (off < n) {
        if (p[off] == 0x1B) return off;
        off++;
    }
    return n;
}

#endif
