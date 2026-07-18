# Building RAMble

## Requirements

- macOS 15+ on Apple Silicon
- Swift 6 toolchain — Xcode Command Line Tools are sufficient
  (`xcode-select --install`)

## Build & run

```sh
swift build                    # debug
swift run -c release           # optimized, run in place
./scripts/make-app.sh          # produce build/RAMble.app (ad-hoc signed)
```

The `.app` bundle sets `LSUIElement` (menu-bar-only agent) and gives macOS a
stable identity for the start-at-login setting (`SMAppService` silently no-ops
when running the bare executable from `.build/`).

## Targets

| Target | Purpose |
|---|---|
| `RAMbleKit` | library: monitors, state, renderer, plugins, themes, UI |
| `RAMble` | executable entry point |
| `RAMbleSelfTest` | dependency-free verification (`swift run RAMbleSelfTest`) |
| `RAMbleTests` | Swift Testing suite — requires full Xcode (`swift test`) |

`swift test` fails on a bare Command Line Tools install because Apple does
not ship XCTest/Swift Testing runtimes with the CLT. `RAMbleSelfTest`
mirrors the suite's coverage and runs anywhere.

## Notes

- Metal shaders compile from source at app startup (`ShaderSource.swift`);
  there is no metallib build step, so plain `swift build` is the whole story.
- Debug builds are dramatically slower in the per-frame physics; always
  benchmark with `-c release`.
- The overlay needs no special permissions or entitlements: all monitoring
  uses public interfaces (Mach host statistics, sysctl, IOKit registry
  properties, `ps`, and localhost HTTP).
