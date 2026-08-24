#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --disable-sandbox

BIN=".build/release/jetty"
BUNDLE=".build/release/Jetty_Jetty.bundle"
PLIST="$ROOT/Resources/Info.plist"
APP="$ROOT/dist/Jetty.app"

if [ ! -x "$BIN" ]; then
	echo "jetty: missing $BIN" >&2
	exit 1
fi
if [ ! -d "$BUNDLE" ]; then
	echo "jetty: missing $BUNDLE" >&2
	exit 1
fi
if [ ! -f "$PLIST" ]; then
	echo "jetty: missing $PLIST" >&2
	exit 1
fi

rm -rf "$APP" "$ROOT/dist/jetty.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BIN" "$APP/Contents/MacOS/jetty"
chmod 755 "$APP/Contents/MacOS/jetty"
ditto "$BUNDLE" "$APP/Contents/Resources/Jetty_Jetty.bundle"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - --identifier dev.jetty.app --timestamp=none "$APP"

echo "jetty: app at $APP"
