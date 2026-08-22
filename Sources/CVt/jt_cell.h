#ifndef JT_CELL_H
#define JT_CELL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Cell {
    uint32_t content;
    uint32_t fg;
    uint32_t bg;
    uint16_t attrs;
    uint16_t extra;
} Cell;

_Static_assert(sizeof(Cell) == 16, "Cell must be 16 bytes");
_Static_assert(offsetof(Cell, extra) == 14, "Cell field order");

#define COLOR_TYPE_SHIFT 24
#define COLOR_PAYLOAD 0x00FFFFFFu
#define COLOR_DEFAULT 0u
#define COLOR_INDEXED (1u << COLOR_TYPE_SHIFT)
#define COLOR_RGB (2u << COLOR_TYPE_SHIFT)

#define CONTENT_PAYLOAD 0x001FFFFFu
#define CONTENT_KIND_SHIFT 21
#define CONTENT_KIND_MASK (3u << CONTENT_KIND_SHIFT)
#define CONTENT_SCALAR 0u
#define CONTENT_GRAPHEME (1u << CONTENT_KIND_SHIFT)

#define CONTENT_WIDE_SHIFT 23
#define CONTENT_WIDE_MASK (3u << CONTENT_WIDE_SHIFT)
#define WIDE_NARROW 0u
#define WIDE_FULL (1u << CONTENT_WIDE_SHIFT)
#define WIDE_TAIL (2u << CONTENT_WIDE_SHIFT)
#define WIDE_HEAD (3u << CONTENT_WIDE_SHIFT)

#define ATTR_BOLD (1u << 0)
#define ATTR_DIM (1u << 1)
#define ATTR_ITALIC (1u << 2)
#define ATTR_BLINK (1u << 3)
#define ATTR_REVERSE (1u << 4)
#define ATTR_HIDDEN (1u << 5)
#define ATTR_STRIKETHROUGH (1u << 6)
#define ATTR_OVERLINE (1u << 7)
#define ATTR_UL_SHIFT 8
#define ATTR_UL_MASK (7u << ATTR_UL_SHIFT)
#define UL_NONE 0u
#define UL_SINGLE (1u << ATTR_UL_SHIFT)
#define UL_DOUBLE (2u << ATTR_UL_SHIFT)
#define UL_CURLY (3u << ATTR_UL_SHIFT)
#define UL_DOTTED (4u << ATTR_UL_SHIFT)
#define UL_DASHED (5u << ATTR_UL_SHIFT)

static inline uint32_t color_default(void) { return COLOR_DEFAULT; }

static inline uint32_t color_indexed(uint8_t i) {
    return COLOR_INDEXED | (uint32_t)i;
}

static inline uint32_t color_rgb(uint8_t r, uint8_t g, uint8_t b) {
    return COLOR_RGB | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

static inline uint32_t color_type(uint32_t c) { return c >> COLOR_TYPE_SHIFT; }

static inline uint32_t color_payload(uint32_t c) { return c & COLOR_PAYLOAD; }

static inline uint32_t content_scalar(uint32_t scalar, uint32_t wide) {
    return (scalar & CONTENT_PAYLOAD) | (wide & CONTENT_WIDE_MASK);
}

static inline size_t jt_cell_extra_offset(void) { return offsetof(Cell, extra); }

#ifdef __cplusplus
}
#endif

#endif
