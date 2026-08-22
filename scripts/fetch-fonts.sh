#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FONTDIR="${ROOT}/Sources/Jetty/Resources/Fonts"
TMP="${ROOT}/.font-fetch"
URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.zip"
SHA="76f05ff3ace48a464a6ca57977998784ff7bdbb65a6d915d7e401cd3927c493c"
mkdir -p "${FONTDIR}" "${TMP}"
cd "${TMP}"
if [ ! -f JetBrainsMono.zip ]; then
  curl -fL -o JetBrainsMono.zip "${URL}"
fi
GOT="$(shasum -a 256 JetBrainsMono.zip | awk '{print $1}')"
if [ "${GOT}" != "${SHA}" ]; then
  echo "jetty: font zip sha256 mismatch: ${GOT}" >&2
  exit 1
fi
rm -rf unpacked
mkdir unpacked
unzip -q -o JetBrainsMono.zip -d unpacked
# Nerd Fonts zip layout varies; find Mono faces.
find unpacked -iname '*NerdFontMono-Regular.ttf' | grep -v NL | head -1 | while read f; do cp -f "$f" "${FONTDIR}/JetBrainsMonoNerdFontMono-Regular.ttf"; done
find unpacked -iname '*NerdFontMono-Italic.ttf' | grep -v NL | grep -v Bold | grep -v Extra | grep -v Semi | grep -v Light | grep -v Medium | grep -v Thin | head -1 | while read f; do cp -f "$f" "${FONTDIR}/JetBrainsMonoNerdFontMono-Italic.ttf"; done
find unpacked -iname '*NerdFontMono-Bold.ttf' | grep -v NL | grep -v Extra | grep -v Semi | head -1 | while read f; do cp -f "$f" "${FONTDIR}/JetBrainsMonoNerdFontMono-Bold.ttf"; done
find unpacked -iname '*NerdFontMono-BoldItalic.ttf' | grep -v NL | grep -v Extra | grep -v Semi | head -1 | while read f; do cp -f "$f" "${FONTDIR}/JetBrainsMonoNerdFontMono-BoldItalic.ttf"; done
find unpacked -iname '*NerdFontMono-ExtraBold.ttf' | grep -v NL | grep -v Italic | head -1 | while read f; do cp -f "$f" "${FONTDIR}/JetBrainsMonoNerdFontMono-ExtraBold.ttf"; done
find unpacked -iname '*NerdFontMono-ExtraBoldItalic.ttf' | grep -v NL | head -1 | while read f; do cp -f "$f" "${FONTDIR}/JetBrainsMonoNerdFontMono-ExtraBoldItalic.ttf"; done
find unpacked -iname 'OFL.txt' | head -1 | while read f; do cp -f "$f" "${FONTDIR}/OFL.txt"; done
ls -la "${FONTDIR}"
