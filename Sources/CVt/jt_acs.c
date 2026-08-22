#include "jt_vt.h"

static const uint32_t k_dec_special[0x20] = {
    0x25C6, /* ` */
    0x2592, /* a */
    0x2409, /* b */
    0x240C, /* c */
    0x240D, /* d */
    0x240A, /* e */
    0x00B0, /* f */
    0x00B1, /* g */
    0x2424, /* h */
    0x240B, /* i */
    0x2518, /* j */
    0x2510, /* k */
    0x250C, /* l */
    0x2514, /* m */
    0x253C, /* n */
    0x23BA, /* o */
    0x23BB, /* p */
    0x2500, /* q */
    0x23BC, /* r */
    0x23BD, /* s */
    0x251C, /* t */
    0x2524, /* u */
    0x2534, /* v */
    0x252C, /* w */
    0x2502, /* x */
    0x2264, /* y */
    0x2265, /* z */
    0x03C0, /* { */
    0x2260, /* | */
    0x00A3, /* } */
    0x00B7, /* ~ */
    0x007F, /* DEL unused */
};

uint32_t jt_acs_map(uint8_t b) {
    if (b < 0x60 || b > 0x7E) return b;
    return k_dec_special[b - 0x60];
}

size_t jt_scan_ascii_no_acs(const uint8_t *p, size_t n) {
    size_t off = 0;
    while (off < n) {
        uint8_t c = p[off];
        if (c < 0x20 || c >= 0x60) return off;
        off++;
    }
    return n;
}
