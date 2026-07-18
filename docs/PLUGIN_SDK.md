# RAMble Plugin SDK

An animation plugin is a class that turns `SystemState` into particles.
No Metal knowledge required — the renderer handles batching, trails, bloom,
and transparency.

## The protocol

```swift
public protocol AnimationPlugin: AnyObject {
    var name: String { get }

    /// Called when the plugin becomes active or the view resizes.
    /// `bounds` is the scene size in points, origin bottom-left.
    func prepare(bounds: SIMD2<Float>, theme: Theme)

    /// Once per frame with the latest unified state. Never query the OS here.
    func update(state: SystemState, deltaTime: Float)

    /// Submit this frame's particles.
    func render(renderer: Renderer)

    /// Optional (default no-op): live theme switches.
    func themeDidChange(_ theme: Theme)
}
```

## Registering

```swift
// Before the app starts (top of main.swift), or from your own target:
PluginRegistry.shared.register(name: "Pulse Ring") { PulseRingPlugin() }
```

Registered plugins automatically appear in the menu bar Animation menu and in
Settings → Appearance. Registering an existing name replaces it.

## Particles

```swift
renderer.submit(Particle(
    position: SIMD2(x, y),        // points, origin bottom-left
    velocity: SIMD2(vx, vy),      // used for streak stretching
    color:    theme.color(2),     // linear RGBA
    size:     3.0,                // radius in points
    glow:     0.5,                // 0…1 extra emission (feeds bloom)
    shape:    .disc))             // .disc | .square | .streak
```

- Submit arrays (`renderer.submit([Particle])`) — one call per batch is
  cheapest. Total capacity is 32,768 instances per frame.
- `.streak` stretches along `velocity` — free motion blur for fast objects.
- Trails come from the renderer's accumulation texture; emit a particle each
  frame and the fade (`theme.trailPersistence`) draws the tail for you.

## Reading state

Everything lives on `SystemState` (see `State/SystemState.swift`): memory,
swap, CPU (incl. per-core and E/P split), GPU, disk, and the AI signals
(`inferenceRunning`, `tokensPerSecond`, `contextLength`, `loadedModels`,
`watchedProcesses`). Use:

- `state.stress` — the one number that should drive your animation's mood.
- One-shot events — `modelJustLoaded`, `modelJustUnloaded`,
  `generationJustFinished` are true for exactly one frame's state: trigger
  bursts, pulses, releases.

## Theming

Respect the active theme so your plugin works across all seven built-ins:

- `theme.color(i)` — palette variety (any integer, wraps safely).
- `theme.stressColor(t)` — calm→warning blend, use for anything that heats up.
- `theme.particleScale`, `theme.glowIntensity` — scale your sizes/glow.

## Rules of good citizenship

1. Clamp `deltaTime` (`min(dt, 1/30)`) so background-tab stalls don't
   explode your physics.
2. Smooth raw signals with EMAs — state updates at 1 Hz; your visuals run at
   60+ FPS.
3. Keep `update` under ~1 ms for a few thousand elements; use spatial
   hashing if you need collisions (see `PlinkoPlugin`).
4. Survive extremes: the self-test drives every registered plugin with
   all-1.0 state for 300 frames. Run `swift run RAMbleSelfTest`.

## Worked example

[`Examples/PulseRingPlugin.swift`](../Examples/PulseRingPlugin.swift) — a
complete ~60-line plugin: RAM sets a ring's radius, stress sets its color,
CPU sets its breathing rate, inference makes it shimmer.
