#!/bin/sh
set -e
cd "$(dirname "$0")/.."
swift build -c release --disable-sandbox
echo "jetty: binary at .build/release/jetty"
