#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "$JETTY_SIGN_IDENTITY" ]; then
	echo "jetty: set JETTY_SIGN_IDENTITY to a Developer ID Application identity" >&2
	exit 1
fi
if [ -z "$JETTY_NOTARY_PROFILE" ]; then
	echo "jetty: set JETTY_NOTARY_PROFILE to a notarytool keychain profile" >&2
	exit 1
fi

"$ROOT/scripts/build-app.sh"

APP="$ROOT/dist/jetty.app"
ZIP="$ROOT/dist/jetty.zip"
ENT="$ROOT/Resources/jetty.entitlements"

codesign --force --sign "$JETTY_SIGN_IDENTITY" \
	--options runtime --timestamp \
	--entitlements "$ENT" \
	--identifier dev.jetty.app \
	"$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$JETTY_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
echo "jetty: stapled $APP"
