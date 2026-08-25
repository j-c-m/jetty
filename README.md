# Jetty

Experimental macOS terminal. Swift 6 + C. `TERM=xterm-256color`.

This is not production software. The goal is to test new ideas in relation to
[Ghostty](https://ghostty.org/). Ghostty has been a clear reference for
implementation. Not affiliated with Ghostty. Differences and why Jetty is a
bit faster / about 2× cheaper on CPU+GPU:
[docs/vs-ghostty.md](docs/vs-ghostty.md).

Not the Eclipse Jetty Java server.

## Requirements

- macOS 14+
- Swift 6 / Xcode CLT

## Build

```
swift test --disable-sandbox
swift build -c release --disable-sandbox
swift run -c release --disable-sandbox
```

App bundle (ad-hoc sign):

```
./scripts/build-app.sh
open dist/Jetty.app
```

Notarize (Developer ID + notarytool keychain profile):

```
JETTY_SIGN_IDENTITY=... JETTY_NOTARY_PROFILE=... ./scripts/notarize.sh
```

## Config

`~/.config/jetty/config`. Keys and internals: [docs/DESIGN.md](docs/DESIGN.md),
[docs/DESIGN-follow-on.md](docs/DESIGN-follow-on.md).

AppleScript is on unless `macos-applescript = false`. Command names match
Ghostty for windows and terminals. No tabs or splits.

## License

MIT. See [LICENSE.md](LICENSE.md) and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
