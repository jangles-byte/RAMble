# RAMble

**AI workload visualization as a living desktop overlay for macOS.**

RAMble is a borderless, transparent, click-through overlay that turns your
Mac's resource usage — and your local LLM activity — into real-time Metal
animations. Traditional monitors show graphs; RAMble shows *systems under
stress*: a galaxy collapsing into a black hole as swap fills, a Plinko board
choking with traffic as memory pressure rises, a factory line backing up as
your machine works.

It feels like a living wallpaper, not a system monitor.

## What it visualizes

| Signal | Source |
|---|---|
| RAM used / free / cached / wired / compressed | Mach `host_statistics64` |
| Memory pressure | OS pressure events + derived compression/swap signal |
| Swap usage, growth rate, page-ins/outs | `sysctl vm.swapusage` + VM stats |
| CPU total, per-core, E-core vs P-core | `host_processor_info` |
| GPU utilization & memory | IOKit `IOAccelerator` statistics |
| Disk read/write throughput | IOKit `IOBlockStorageDriver` statistics |
| Ollama / LM Studio / llama.cpp / vLLM / Open WebUI | process watching + local HTTP APIs |
| Model load/unload, context length, generation activity | Ollama `/api/ps`, OpenAI-compatible `/v1/models` |

Everything folds into a single normalized **stress score** (0…1) that drives
every animation, plus one-shot events (model loaded → burst effect,
generation finished → particle release).

> Tokens/sec is an intensity *estimate* derived from accelerator activity —
> local servers don't expose live token counters.

## The five animations

- **Plinko** — glowing memory allocations fall through pegs (memory channels).
  Pressure creates traffic jams and stacking; swap spills red overflow.
- **Galaxy** — 2,600 stars orbit a core. Pressure drags orbits inward; heavy
  swap forms a black hole with an accretion ring that swallows stars.
- **Water Tank** — a glass reservoir. Water level = RAM, wave intensity =
  memory pressure, swap = the tank overflows down its sides.
- **Motherboard** — data packets route between CPU cores, RAM modules, GPU,
  and disk. Congestion visibly backs packets up along the traces; swap opens
  glowing red RAM→disk routes.
- **Factory** — conveyor belts, gears, and machines. Gears spin with CPU
  (P-cores drive the big gears), memory pressure slows the machines so crate
  backlogs pile up, swap rejects crates off the end of the line.

Seven themes — Glass, Cyberpunk, Minimal, Synthwave, Terminal, Dark, Light —
restyle colors, glow, trails, and particle sizing.

## Quick start

Requirements: macOS 15+, Apple Silicon, Swift 6 toolchain
(Command Line Tools are enough to build and run).

```sh
git clone <this repo> && cd RAMble
swift run -c release           # run directly, or:
./scripts/make-app.sh          # build build/RAMble.app
cp -R build/RAMble.app /Applications/
```

RAMble lives in the menu bar (memory-chip icon): toggle the overlay, switch
animations, open Settings, quit. The overlay is click-through and sits above
the wallpaper but below your windows — it never interferes with normal use.

## Settings

Animation, theme, opacity, scale, FPS limit (30/60/90/120), per-display
enable, extra watched processes, hide Dock icon, start at login.

## Performance

Rendering is a single instanced draw of up to 32k particles plus a trail/bloom
post chain; monitors sample at 1 Hz (fast path) and 2.5 Hz (process/HTTP
path). On an M-series machine the release build runs a few percent CPU at
60 FPS; drop the FPS limit to 30 for near-idle operation. Debug builds are
much heavier — always measure with `-c release`.

## Verifying

```sh
swift run RAMbleSelfTest   # dependency-free check suite (works with CLT only)
swift test                 # Swift Testing suite (requires full Xcode)
```

## Extending

Animations are plugins behind a small protocol — see
[docs/PLUGIN_SDK.md](docs/PLUGIN_SDK.md) and the ~60-line
[Examples/PulseRingPlugin.swift](Examples/PulseRingPlugin.swift).
Architecture details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Build details: [docs/BUILDING.md](docs/BUILDING.md).
