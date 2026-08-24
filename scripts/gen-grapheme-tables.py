#!/usr/bin/env python3
"""Emit Sources/CVt/jt_gb_props.inc and jt_gb_precompute.inc from UCD 17.0.0.

Packing matches Ghostty uucode GraphemeBreakNoControl + BreakState:
  props byte: gb:5, emoji_vs_base:1, width_zero_in_grapheme:1
  precompute key u13: state:3, gb1:5, gb2:5 (LSB first)
  precompute value: result:1, state:3
"""

from __future__ import annotations

import os
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CVT = os.path.join(ROOT, "Sources", "CVt")
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "unicode")
UCD = "https://www.unicode.org/Public/17.0.0/ucd"
NCP = 0x110000

GB = {
    "other": 0,
    "prepend": 1,
    "regional_indicator": 2,
    "spacing_mark": 3,
    "l": 4,
    "v": 5,
    "t": 6,
    "lv": 7,
    "lvt": 8,
    "zwj": 9,
    "zwnj": 10,
    "extended_pictographic": 11,
    "emoji_modifier_base": 12,
    "emoji_modifier": 13,
    "indic_conjunct_break_extend": 14,
    "indic_conjunct_break_linker": 15,
    "indic_conjunct_break_consonant": 16,
}

ST_DEFAULT = 0
ST_RI = 1
ST_EXT_PIC = 2
ST_INCB_CONSONANT = 3
ST_INCB_LINKER = 4

GBP = {
    "Prepend": "prepend",
    "CR": "cr",
    "LF": "lf",
    "Control": "control",
    "Extend": "extend",
    "Regional_Indicator": "regional_indicator",
    "SpacingMark": "spacing_mark",
    "L": "l",
    "V": "v",
    "T": "t",
    "LV": "lv",
    "LVT": "lvt",
    "ZWJ": "zwj",
}

ZWNJ = 0x200C
ZWJ = 0x200D


def fetch(name: str) -> str:
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, os.path.basename(name))
    if not os.path.isfile(path):
        url = f"{UCD}/{name}"
        print(f"fetch {url}")
        urllib.request.urlretrieve(url, path)
    with open(path, encoding="utf-8") as f:
        return f.read()


def parse_cps(spec: str) -> range:
    spec = spec.strip()
    if ".." in spec:
        a, b = spec.split("..", 1)
        return range(int(a, 16), int(b, 16) + 1)
    v = int(spec, 16)
    return range(v, v + 1)


def parse_ucd_semi(text: str):
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or ";" not in line:
            continue
        spec, rest = line.split(";", 1)
        yield spec.strip(), rest.strip()


def load_gbp() -> list[str]:
    orig = ["other"] * NCP
    text = fetch("auxiliary/GraphemeBreakProperty.txt")
    for spec, rest in parse_ucd_semi(text):
        tag = rest.split(";")[0].strip()
        name = GBP.get(tag)
        if not name:
            continue
        for cp in parse_cps(spec):
            if cp < NCP:
                orig[cp] = name
    return orig


def load_incb() -> list[str]:
    incb = ["none"] * NCP
    text = fetch("DerivedCoreProperties.txt")
    for spec, rest in parse_ucd_semi(text):
        parts = [p.strip() for p in rest.split(";")]
        if not parts:
            continue
        if parts[0] != "InCB":
            continue
        kind = parts[1].lower() if len(parts) > 1 else "none"
        if kind not in ("linker", "consonant", "extend"):
            continue
        for cp in parse_cps(spec):
            if cp < NCP:
                incb[cp] = kind
    return incb


def load_bool_prop(path: str, prop: str) -> bytearray:
    flags = bytearray(NCP)
    text = fetch(path)
    for spec, rest in parse_ucd_semi(text):
        tag = rest.split(";")[0].strip()
        if tag != prop:
            continue
        for cp in parse_cps(spec):
            if cp < NCP:
                flags[cp] = 1
    return flags


def load_vs_base() -> bytearray:
    flags = bytearray(NCP)
    text = fetch("emoji/emoji-variation-sequences.txt")
    for spec, _rest in parse_ucd_semi(text):
        parts = spec.split()
        if len(parts) < 2:
            continue
        cp = int(parts[0], 16)
        vs = int(parts[1], 16)
        if vs in (0xFE0E, 0xFE0F) and cp < NCP:
            flags[cp] = 1
    return flags


def load_gc() -> list[str]:
    gc = ["Cn"] * NCP
    text = fetch("UnicodeData.txt")
    for raw in text.splitlines():
        parts = raw.split(";")
        if len(parts) < 3:
            continue
        cp = int(parts[0], 16)
        if cp < NCP:
            gc[cp] = parts[2]
    return gc


def load_eaw_wide() -> bytearray:
    wide = bytearray(NCP)
    text = fetch("EastAsianWidth.txt")
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("# @missing:"):
            body = line[len("# @missing:") :].strip()
            if ";" not in body:
                continue
            spec, rest = body.split(";", 1)
            tag = rest.strip().split()[0]
            if tag in ("W", "F"):
                for cp in parse_cps(spec):
                    if cp < NCP:
                        wide[cp] = 1
            continue
        if not line or line.startswith("#"):
            continue
        if ";" not in line:
            continue
        spec, rest = line.split(";", 1)
        tag = rest.split("#", 1)[0].strip()
        if tag in ("W", "F"):
            for cp in parse_cps(spec):
                if cp < NCP:
                    wide[cp] = 1
    return wide


def derive_gb(orig: list[str], incb: list[str], emoji_mod: bytearray, emoji_base: bytearray, ext_pic: bytearray) -> list[int]:
    out = [GB["other"]] * NCP
    for cp in range(NCP):
        o = orig[cp]
        if emoji_mod[cp]:
            out[cp] = GB["emoji_modifier"]
            continue
        if emoji_base[cp]:
            out[cp] = GB["emoji_modifier_base"]
            continue
        if ext_pic[cp]:
            out[cp] = GB["extended_pictographic"]
            continue
        kind = incb[cp]
        if kind == "none":
            if o == "extend":
                out[cp] = GB["zwnj"] if cp == ZWNJ else GB["indic_conjunct_break_extend"]
            elif o in ("cr", "lf", "control"):
                out[cp] = GB["other"]
            elif o in GB:
                out[cp] = GB[o]
            else:
                out[cp] = GB["other"]
        elif kind == "extend":
            out[cp] = GB["zwj"] if cp == ZWJ else GB["indic_conjunct_break_extend"]
        elif kind == "linker":
            out[cp] = GB["indic_conjunct_break_linker"]
        elif kind == "consonant":
            out[cp] = GB["indic_conjunct_break_consonant"]
    return out


def standalone_width(cp: int, gc: str, ignorable: int, eaw_wide: int, gb: int) -> int:
    if gc in ("Cc", "Cs", "Zl", "Zp"):
        return 0
    if cp == 0x00AD:
        return 1
    if ignorable:
        return 0
    if cp == 0x2E3A:
        return 2
    if cp == 0x2E3B:
        return 3
    if eaw_wide:
        return 2
    if gb == GB["regional_indicator"]:
        return 2
    return 1


def is_extend(gb: int) -> bool:
    return gb in (GB["zwnj"], GB["indic_conjunct_break_extend"], GB["indic_conjunct_break_linker"])


def is_incb_extend(gb: int) -> bool:
    return gb in (GB["indic_conjunct_break_extend"], GB["zwj"])


def is_ext_pic(gb: int) -> bool:
    return gb in (GB["extended_pictographic"], GB["emoji_modifier_base"])


def compute_break(gb1: int, gb2: int, state: int) -> tuple[bool, int]:
    st = state
    if st == ST_RI:
        if gb1 != GB["regional_indicator"] or gb2 != GB["regional_indicator"]:
            st = ST_DEFAULT
    elif st == ST_EXT_PIC:
        keep = (
            GB["indic_conjunct_break_extend"],
            GB["indic_conjunct_break_linker"],
            GB["zwnj"],
            GB["zwj"],
            GB["extended_pictographic"],
            GB["emoji_modifier_base"],
            GB["emoji_modifier"],
        )
        if gb1 not in keep:
            st = ST_DEFAULT
        if gb2 not in keep:
            st = ST_DEFAULT
    elif st in (ST_INCB_CONSONANT, ST_INCB_LINKER):
        keep = (
            GB["indic_conjunct_break_consonant"],
            GB["indic_conjunct_break_linker"],
            GB["indic_conjunct_break_extend"],
            GB["zwj"],
        )
        if gb1 not in keep:
            st = ST_DEFAULT
        if gb2 not in keep:
            st = ST_DEFAULT

    if gb1 == GB["l"] and gb2 in (GB["l"], GB["v"], GB["lv"], GB["lvt"]):
        return False, st
    if gb1 in (GB["lv"], GB["v"]) and gb2 in (GB["v"], GB["t"]):
        return False, st
    if gb1 in (GB["lvt"], GB["t"]) and gb2 == GB["t"]:
        return False, st
    if gb2 == GB["spacing_mark"]:
        return False, st
    if gb1 == GB["prepend"]:
        return False, st

    if gb1 == GB["indic_conjunct_break_consonant"]:
        if is_incb_extend(gb2):
            return False, ST_INCB_CONSONANT
        if gb2 == GB["indic_conjunct_break_linker"]:
            return False, ST_INCB_LINKER
    elif st == ST_INCB_CONSONANT:
        if gb2 == GB["indic_conjunct_break_linker"]:
            return False, ST_INCB_LINKER
        if is_incb_extend(gb2):
            return False, st
        st = ST_DEFAULT
    elif st == ST_INCB_LINKER:
        if gb2 == GB["indic_conjunct_break_linker"] or is_incb_extend(gb2):
            return False, st
        if gb2 == GB["indic_conjunct_break_consonant"]:
            return False, ST_DEFAULT
        st = ST_DEFAULT

    if is_ext_pic(gb1):
        if is_extend(gb2) or gb2 == GB["zwj"]:
            return False, ST_EXT_PIC
        if gb1 == GB["emoji_modifier_base"] and gb2 == GB["emoji_modifier"]:
            return False, ST_EXT_PIC
    elif st == ST_EXT_PIC:
        if (is_extend(gb1) or gb1 == GB["emoji_modifier"]) and (is_extend(gb2) or gb2 == GB["zwj"]):
            return False, st
        if gb1 == GB["zwj"] and is_ext_pic(gb2):
            return False, ST_DEFAULT
        st = ST_DEFAULT

    if gb1 == GB["regional_indicator"] and gb2 == GB["regional_indicator"]:
        if st == ST_DEFAULT:
            return False, ST_RI
        return True, ST_DEFAULT

    if is_extend(gb2) or gb2 == GB["zwj"]:
        return False, st
    return True, st


def emit_bytes(path: str, name: str, data: bytes, comment: str) -> None:
    lines = [
        f"/* Generated by scripts/gen-grapheme-tables.py. {comment} */",
        f"static const uint8_t {name}[{len(data)}] = {{",
    ]
    chunk = 16
    for i in range(0, len(data), chunk):
        part = data[i : i + chunk]
        body = ", ".join(f"0x{b:02X}" for b in part)
        comma = "," if i + chunk < len(data) else ""
        lines.append(f"    {body}{comma}")
    lines.append("};")
    lines.append("")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"wrote {path} ({len(data)} bytes)")


def main() -> None:
    orig = load_gbp()
    incb = load_incb()
    emoji_mod = load_bool_prop("emoji/emoji-data.txt", "Emoji_Modifier")
    emoji_base = load_bool_prop("emoji/emoji-data.txt", "Emoji_Modifier_Base")
    ext_pic = load_bool_prop("emoji/emoji-data.txt", "Extended_Pictographic")
    vs_base = load_vs_base()
    ignorable = load_bool_prop("DerivedCoreProperties.txt", "Default_Ignorable_Code_Point")
    gc = load_gc()
    eaw = load_eaw_wide()
    gb = derive_gb(orig, incb, emoji_mod, emoji_base, ext_pic)

    props = bytearray(NCP)
    for cp in range(NCP):
        g = gb[cp]
        w = standalone_width(cp, gc[cp], ignorable[cp], eaw[cp], g)
        if cp == 0x20E3:
            w = 2
        wz = (
            w == 0
            or emoji_mod[cp]
            or gc[cp] in ("Mn", "Me")
            or g in (GB["v"], GB["t"], GB["prepend"])
        )
        props[cp] = g | (0x20 if vs_base[cp] else 0) | (0x40 if wz else 0)

    pre = bytearray(8192)
    for st in range(5):
        for g1 in range(17):
            for g2 in range(17):
                brk, nst = compute_break(g1, g2, st)
                key = st | (g1 << 3) | (g2 << 8)
                pre[key] = (1 if brk else 0) | ((nst & 7) << 1)

    emit_bytes(
        os.path.join(CVT, "jt_gb_props.inc"),
        "jt_gb_props",
        bytes(props),
        "UCD 17.0.0 grapheme-break / VS / width-zero, 1 byte per codepoint",
    )
    emit_bytes(
        os.path.join(CVT, "jt_gb_precompute.inc"),
        "jt_gb_precompute",
        bytes(pre),
        "Ghostty Precompute 8 KiB (state, gb1, gb2)",
    )


if __name__ == "__main__":
    main()
