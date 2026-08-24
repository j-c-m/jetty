#include "jt_vt.h"

#include "jt_gb_props.inc"
#include "jt_gb_precompute.inc"

#define JT_GB_MASK 0x1Fu
#define JT_GB_VS 0x20u
#define JT_GB_WZ 0x40u

static uint8_t gb_props(uint32_t cp) {
    if (cp >= 0x110000u) return 0x40u;
    return jt_gb_props[cp];
}

int jt_grapheme_break(uint32_t cp1, uint32_t cp2, uint8_t *state) {
    uint8_t gb1 = gb_props(cp1) & JT_GB_MASK;
    uint8_t gb2 = gb_props(cp2) & JT_GB_MASK;
    uint8_t st = state ? *state : 0;
    if (st > 4) st = 0;
    uint16_t key = (uint16_t)st | ((uint16_t)gb1 << 3) | ((uint16_t)gb2 << 8);
    uint8_t v = jt_gb_precompute[key];
    if (state) *state = (uint8_t)((v >> 1) & 7u);
    return (int)(v & 1u);
}

int jt_gb_emoji_vs_base(uint32_t cp) {
    return (gb_props(cp) & JT_GB_VS) != 0;
}

int jt_gb_width_zero(uint32_t cp) {
    return (gb_props(cp) & JT_GB_WZ) != 0;
}

int jt_grapheme_width_effect(uint32_t prev, uint32_t cp) {
    if (cp == 0xFE0Fu || cp == 0xFE0Eu) {
        if (!jt_gb_emoji_vs_base(prev)) return JT_GB_IGNORE;
        return cp == 0xFE0Fu ? JT_GB_WIDE : JT_GB_NARROW;
    }
    if (!jt_gb_width_zero(cp)) return JT_GB_WIDE;
    return JT_GB_NO_CHANGE;
}
