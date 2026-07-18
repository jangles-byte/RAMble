# RAMble Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                        Monitors (RAMbleKit/Monitoring)         │
│  MemoryMonitor  CPUMonitor  GPUMonitor  DiskMonitor            │
│  ProcessMonitor (ps @ 2.5s)   LLMMonitor (HTTP @ 2.5s)         │
└───────────────┬────────────────────────────────────────────────┘
                │ raw samples (background queue)
                ▼
┌────────────────────────────────────────────────────────────────┐
│  StateEngine ──▶ SystemState (single immutable snapshot)       │
│                  + StressEngine (weighted blend + peak bias    │
│                    + asymmetric EMA smoothing)                 │
└───────────────┬────────────────────────────────────────────────┘
                │ @Published on main thread (Combine)
                ▼
┌────────────────────────────────────────────────────────────────┐
│  OverlayController — one per-display stack of:                 │
│    OverlayWindow (borderless/transparent/click-through)        │
│    └─ MTKView ── Renderer (MTKViewDelegate)                    │
│                   └─ activePlugin: AnimationPlugin             │
└────────────────────────────────────────────────────────────────┘
```

## Data-flow rules

1. **Animations never touch the OS.** Plugins read only `SystemState`.
   This keeps them testable (see `RAMbleSelfTest`), swappable, and cheap.
2. **Monitors never touch the UI.** They produce plain sample structs on a
   utility queue; `StateEngine` folds them and hops to the main thread once.
3. **One snapshot per tick.** `SystemState` is a value type; every consumer
   sees a consistent view. One-shot flags (`modelJustLoaded`, …) are set on
   exactly one published snapshot.

## Monitoring cadence

- **Fast path (1 Hz):** memory, CPU, GPU, disk — cheap syscalls/IOKit reads.
- **Slow path (2.5 Hz):** `ps` process sampling and LLM HTTP polls
  (sub-second timeouts, ephemeral session). Results are merged into the next
  fast tick.

Rendering runs at display cadence (30–120 FPS) and interpolates visually via
its own smoothing (EMAs inside plugins), so 1 Hz data still animates fluidly.

## Stress engine

`stress = clamp(weightedAvg * (1 - peakBias) + worstSignal * peakBias)`

- Weights favor memory signals (pressure 0.25, RAM 0.20, swap 0.20) because
  RAMble is a RAM-first visualizer.
- `peakBias = 0.35` makes a single saturated subsystem register even when the
  average looks calm (maxed swap on an idle CPU *is* a problem).
- The EMA rises 2.5× faster than it falls: spikes appear instantly, recovery
  breathes out slowly.

## Renderer

A reusable Metal engine (`RAMbleKit/Rendering`):

- **Instancing:** every visual element is a `Particle` (position, velocity,
  color, size, glow, shape: disc/square/streak). One buffer upload + one
  instanced draw per frame; 32k instance capacity, triple-buffered with a
  semaphore so the CPU never races the GPU.
- **Trails:** an accumulation texture persists between frames and is faded
  multiplicatively each frame via blend-state (no extra sampling pass).
  `Theme.trailPersistence` controls the decay.
- **Bloom:** bright-pass threshold into a quarter-res texture, MPS Gaussian
  blur, additive composite. Skipped entirely when the theme's glow is ~0.
- **Transparency:** the drawable clears to alpha 0 and composites straight
  alpha, so the overlay window shows the desktop through empty space.
- **Shaders** are compiled from source at startup (`ShaderSource.swift`) —
  no metallib pipeline, keeps the project a plain SwiftPM package.

## Windows

`OverlayWindow` is borderless, `backgroundColor = .clear`,
`ignoresMouseEvents = true` (click-through), level = desktop-icon window + 1
(above wallpaper, below every normal window), joins all Spaces, stationary,
excluded from window cycling. `OverlayController` maintains one window +
renderer per `NSScreen` and reacts to display connect/disconnect via
`didChangeScreenParametersNotification`.

## LLM integration

- **Ollama** `/api/ps`: loaded model names + context length.
- **OpenAI-compatible** `/v1/models` (LM Studio :1234, llama.cpp :8080,
  vLLM :8000): available model IDs → "server is up with model loaded".
- Model load/unload = set difference between polls → one-shot flags.
- Inference detection: a watched process sustaining >50% of one core for two
  consecutive slow ticks. Tokens/sec is an *estimate*:
  `max(gpuUsage, processCPU) × nominalPeakRate`, EMA-smoothed — local
  servers expose no live token counters, and plugins only need an intensity
  signal.

## Module layout

- `Sources/RAMbleKit` — everything: monitors, state, rendering, plugins,
  themes, app UI (library so tests and the self-test runner can import it).
- `Sources/RAMble` — 8-line executable entry point.
- `Sources/RAMbleSelfTest` — dependency-free verification runner.
- `Tests/RAMbleTests` — Swift Testing suite (needs full Xcode).
