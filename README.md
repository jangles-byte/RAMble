<p align="center">
  <img src="assets/logo.png" width="180" alt="RAMble — a white ram's head on a dark tile">
</p>

<h1 align="center">RAMble</h1>

<p align="center"><strong>Watch your Mac think.</strong></p>

<p align="center">
  <a href="https://github.com/jangles-byte/RAMble/releases/latest"><img src="https://img.shields.io/github/v/release/jangles-byte/RAMble?label=download&color=4c6ef5" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-native-8a63d2" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift%206%20%2B%20Metal-no%20Electron-f05138" alt="Swift 6 + Metal">
</p>

RAMble is a free, native macOS overlay that turns your system's inner life —
RAM pressure, CPU, GPU, swap, and your local LLMs — into living, glowing
animations on your desktop. When Ollama streams tokens, you *see* a neural
network firing. When memory pressure climbs, you *see* the machine strain. No
graphs, no numbers — you just know, at a glance, like watching weather.

It sits behind your windows (or in front, your call), never catches a click,
and idles light enough to leave on all day.

- **Native** — Swift + Metal, Apple Silicon. No Electron, no browser, no ports.
- **Private** — reads public system counters and localhost only. Nothing
  leaves your machine, no analytics, no accounts.
- **Open** — MIT-spirited source, plugin SDK, ~zero dependencies.

---

## The animations

| | |
|---|---|
| **Synapse** ⭐ | The flagship. A living neural graph — colored nodes joined by curved fibers, signal pulses racing along the edges and triggering cascade fires downstream. Idle, it has a resting heartbeat; run a local LLM and it storms. This is what "the model is thinking" looks like. |
| **Plinko** | Glowing marbles (memory allocations) rain through a peg board. Pressure jams the board; swap spills red overflow; escapees bounce along your real screen bottom and fade away. |
| **Galaxy** | 2,600 stars in wound spiral arms with nebula haze. Load speeds the spin; memory pressure drags orbits inward; heavy swap collapses the core into a black hole with an accretion ring. |
| **Water Tank** | A glass reservoir. Water level = RAM. Pressure whips up the waves, CPU simmers bubbles from below, swap overflows the rim in red. |
| **Motherboard** | Data packets route between CPU cores, RAM modules, GPU, and disk. Congestion backs traffic up along the traces; jammed packets buzz; swap opens red packet routes to disk. |
| **Factory** | Conveyor belts, spinning gears (P-cores drive the big ones), machines that fall behind under pressure so crates pile up — and get rejected off the line when you hit swap. |

Seven themes (Glass, Cyberpunk, Minimal, Synthwave, Terminal, Dark, Light)
restyle everything, and an **Intensity slider** runs the whole show from
slow-drip-zen to full chaos.

## What it watches

- **Memory** — used / free / cached / wired / compressed, real memory
  pressure, and swap (usage, growth, page-ins/outs)
- **CPU** — total, per-core, efficiency vs performance cores
- **GPU** — utilization via IOKit
- **Disk** — read/write throughput
- **Local AI** — Ollama, LM Studio, llama.cpp, vLLM, Open WebUI, and any
  process you add: model loads/unloads, context length, and generation
  activity (model load = burst; tokens = firing; finish = ripple)

> Honesty note: local LLM servers don't expose live token counters, so
> tokens/sec is an intensity estimate derived from accelerator activity —
> perfect for driving visuals, not for benchmarking.

---

## Install

### Option 1 — Download (easiest)

1. Grab **`RAMble.app.zip`** from the
   [latest release](https://github.com/jangles-byte/RAMble/releases/latest).
2. Unzip it and drag **RAMble.app** into your **Applications** folder.
3. **First launch:** right-click (or Control-click) RAMble.app and choose
   **Open**, then **Open** again in the dialog. This is only needed once —
   macOS asks because the app is community-built rather than
   Apple-notarized. (If macOS still refuses, run
   `xattr -dr com.apple.quarantine /Applications/RAMble.app` in Terminal
   and open it again.)

That's it. Look for the **ram-head icon in your menu bar** — RAMble has no
Dock icon and no window; the menu bar icon is the whole interface.

### Option 2 — Build from source (5 minutes, no Xcode needed)

Requirements: macOS 15+, Apple Silicon, and the Swift toolchain from Apple's
Command Line Tools.

```sh
# 1. Get the toolchain (skip if you already have git/swift):
xcode-select --install

# 2. Clone and build:
git clone https://github.com/jangles-byte/RAMble.git
cd RAMble
./scripts/make-app.sh

# 3. Install and launch:
cp -R build/RAMble.app /Applications/
open /Applications/RAMble.app
```

Want to try it without installing? `swift run -c release` runs it in place.

---

## Using RAMble

Everything lives under the **ram-head menu bar icon** (top-right of your
screen):

- **Show Overlay** — toggle the animation on/off
- **Animation** — switch between Synapse, Plinko, Galaxy, Water Tank,
  Motherboard, Factory
- **Settings…** — the good stuff (below)
- **Check for Updates…** — one-click update to the latest release
- **Quit RAMble**

The overlay draws **behind your windows**, on the desktop itself — hide or
move a window (or press F11) to see it. It's fully click-through: it can
never steal a click, a keystroke, or focus.

### Settings tour

**Appearance**
- **Bring to front** — float the animation *over* all your windows instead
  (still click-through). Pair with the opacity slider to keep working
  through it.
- **Intensity** — tortoise-to-hare slider. Left: sparse and calm even under
  load. Right: busy screen even at idle. System load layers on top either
  way. (Lower intensity also means less CPU spent.)
- **Opacity / Scale** — how visible, how big. Scale shrinks the scene from
  the center; physics objects can tumble out of a shrunken scene and bounce
  along your real screen edges before fading away.
- **Animation / Theme / Frame rate** — pick your look; 30 FPS roughly halves
  RAMble's cost vs 60.

**Displays** — choose which monitors show the overlay.

**Monitoring**
- **Desktop meters** — a compact, draggable panel of live bars (RAM,
  pressure, swap, CPU, GPU, disk, stress, tokens/sec). Click and hold to
  drag it anywhere; it can't be lost off-screen; picking a corner resets it.
- **Watched processes** — add your own process names (comma-separated) to
  the AI watch list.
- **Live state** — the raw numbers, if you want to peek behind the curtain.

**General** — start at login, hide/show Dock icon, version + **Check for
Updates** button.

### See it react (the fun part)

```sh
# If you use Ollama:
ollama run llama3.2 "write me a limerick about RAM"
```

Watch Synapse light up while tokens stream — bursts on model load, cascade
storms during generation, a ripple when it finishes. No LLM handy? Open a
few heavy apps or build some code and watch the stress climb.

## Updating

Menu bar icon → **Check for Updates…** → click **Update to X**. RAMble
downloads the new version, swaps itself, and relaunches. Done.

## Uninstall

Quit RAMble from the menu bar, then drag `/Applications/RAMble.app` to the
Trash. There are no background helpers; settings live in standard macOS
preferences and weigh a few KB.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "I opened it and nothing happened" | That's almost the point — check the **menu bar** for the ram icon, then hide a window to see the desktop. |
| Can't see the animation | Menu bar icon → make sure **Show Overlay** is checked; Settings → Displays → your monitor is enabled; try **Bring to front** to rule out wallpaper utilities that cover the desktop layer. |
| macOS won't open the app | Right-click → **Open** → **Open**. Still stuck: `xattr -dr com.apple.quarantine /Applications/RAMble.app` |
| Feels heavy | Settings → Appearance: drop **Frame rate** to 30 and/or pull **Intensity** left. Debug builds are slow — always use the release build. |
| LLM activity not detected | RAMble polls Ollama on `:11434` and OpenAI-compatible servers on `:1234`/`:8080`/`:8000`. Custom setup? Add your server's process name under Settings → Monitoring. |
| Meters panel vanished | Settings → Monitoring → pick any corner — that resets its position. |

## Performance

Release builds render up to ~32k particles through a single instanced Metal
draw with trail and bloom post-passes. Monitoring samples at 1 Hz (system)
and 2.5 Hz (processes + LLM HTTP), so the watcher itself is near-free. Your
levers: FPS limit, Intensity, and animation choice. At 30 FPS + low
intensity, RAMble fades into single-digit-idle territory; at 120 FPS +
maximum chaos, it's a light show and priced accordingly.

## For developers

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — monitors → unified
  `SystemState` → stress engine → Metal renderer → plugins.
- **[docs/PLUGIN_SDK.md](docs/PLUGIN_SDK.md)** — write your own animation
  in ~60 lines; see [Examples/PulseRingPlugin.swift](Examples/PulseRingPlugin.swift).
- **[docs/BUILDING.md](docs/BUILDING.md)** — targets, tests, packaging.
- Verify any change with `swift run RAMbleSelfTest` (60+ checks, no Xcode
  required).

Built with Swift 6, SwiftUI, Metal, and Combine. PRs welcome.
