#include "jt_vt.h"

#include "jt_width.inc"

int jt_codepoint_width(uint32_t cp) {
    if (cp >= 0x110000u) return 1;
    uint8_t b = jt_width_lut[cp >> 2];
    return (int)((b >> ((cp & 3u) * 2u)) & 3u);
}
