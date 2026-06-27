# Design notes

## Goal

Cap a native Metal game's frame rate on a fanless Apple Silicon laptop to cut GPU
power/heat while keeping input latency low, independent of the game's VSync setting.
The cap must be configurable and tunable at runtime.

A frame limiter can only add waits — it caps downward and cannot raise a game above the
rate it already produces. An above-refresh target (e.g. 80 on a 60 Hz panel) therefore
only does anything when the game genuinely free-runs above refresh with VSync off.

## Hook point

The chosen interception point is **`-[CAMetalLayer nextDrawable]`**:

- `CAMetalLayer` is a public, concrete class, so it can be obtained by name
  (`objc_getClass("CAMetalLayer")`) and its method swizzled globally with
  `method_setImplementation` — no per-instance discovery needed.
- It sits on the critical path of every Metal present, regardless of whether the game
  uses `MTKView`, a hand-rolled renderer, or SDL2's Metal backend.
- Pacing here propagates back-pressure: holding the render loop drains the in-flight
  drawable pool, which stalls the GPU pipeline and reduces real work — not just display
  latency.

### Pacing vs. `presentDrawable:afterMinimumDuration:`

An alternative is to rewrite `presentDrawable:` to
`presentDrawable:afterMinimumDuration:`. That delegates pacing to CoreAnimation and is
jitter-free, **but** `afterMinimumDuration` is a *minimum frame duration rounded up to a
whole refresh interval*. On a 60 Hz panel it can never exceed 60 fps and collapses any
target in (30, 60) to 30 (`1/58 s = 17.24 ms` rounds up to two refreshes = 33.3 ms). It's
useful only for exact refresh divisors, and useless for an above-refresh target, so the
primary mechanism is direct `mach_wait_until` pacing, which handles arbitrary targets.

### Adaptive VSync

`displaySyncEnabled` is set per the current target on the primary layer:

- `target > refresh` → `displaySyncEnabled = NO`, so the engine can produce frames faster
  than the panel refreshes (tearing on a fixed panel — the cost of lower latency).
- `target ≤ refresh` → restore the layer's original `displaySyncEnabled`.

The change is applied inside a disabled-action `CATransaction`, only when it needs to flip.

### Clock and sleep

- Deadlines accumulate (`next = prev + period`) so there is no per-frame drift, but never
  build up debt: after a long stall the schedule resyncs to "now + period".
- The sleep is `mach_wait_until` — no busy-waiting, since burning a core to shave sub-ms
  jitter would defeat the power-saving purpose.
- The render thread is pinned to user-interactive QoS and a light App Nap assertion is
  held, so the OS doesn't coalesce the paced sleeps. (A foreground game is never napped
  anyway; this is a safety net, and both are configurable.)

### Primary-layer selection

If a game presents more than one `CAMetalLayer` per frame (e.g. a UI overlay), pacing each
independently would over-throttle. The largest layer by drawable area is treated as the
"primary" and is the only one paced; others pass through untouched.

## Recon (the reason most Steam games need no re-signing)

On Apple Silicon all loaded code must be validly signed, so the injected dylib is ad-hoc
signed. Beyond that, `DYLD_INSERT_LIBRARIES` is honored unless the target is "restricted":
a hardened runtime without `allow-dyld-environment-variables`, library validation that
rejects foreign dylibs, a `__RESTRICT` segment, or setuid.

Inspecting the primary test target (a native arm64 Metal game) showed none of those:

| Property | Value | Consequence |
|---|---|---|
| Arch | `arm64` | native Metal |
| Linkage | `Metal`, `MetalKit`, `QuartzCore` (+ SDL2 for windowing) | presents via `CAMetalLayer` |
| Code signature flags | `0x2(adhoc)` — no `runtime` flag | **no hardened runtime** |
| Entitlements | `disable-library-validation`, `get-task-allow` | foreign dylibs load freely |
| `__RESTRICT` segment | absent | DYLD env vars are not stripped |

So injection works with **no modification to the game**, and game updates can't revert
anything because the bundle is never touched. `scripts/check-target.sh` reproduces this
check for any target and prints a verdict.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Above-refresh target unreachable (engine refresh-gated) | Works only if the game free-runs >refresh with VSync off; otherwise the useful range is ≤ refresh. |
| Tearing above refresh on a fixed panel | Inherent and accepted; adaptive VSync keeps VSync on at/below refresh. |
| Non-divisor judder below refresh | Prefer 30/20/15; document the trade-off. |
| Multiple layers / overlays | Pace only the largest (primary) layer. |
| Timer coalescing under power management | User-interactive QoS + App Nap assertion on the render thread. |
| Forcing VSync off destabilising engine timing | Only `displaySyncEnabled` is touched; can be left alone via configuration. |
| Anti-cheat (EAC/BattlEye/VAC) | Single-player only; injection will be flagged in multiplayer. |
| Hardened/notarised targets | `check-target.sh` detects them; re-sign procedure documented in the README. |

## Possible future: an on-screen overlay with power draw

Apple's Metal HUD shows frame rate but isn't extensible and can't show GPU power. A built-in
overlay that draws both fps and watts (toggled by hotkey) is feasible but a meaningfully
larger feature:

- **Power** can be read in-process **without root** via the `IOReport` framework's energy
  channels (the approach tools like `macmon` use), sampled on a background thread.
- **Drawing** is the harder part: the overlay would have to render into the game's drawable
  from the swizzled present (a small Metal text pass) or float a high-window-level
  borderless `NSWindow` over the game. Both are workable but need per-game testing,
  especially for exclusive-fullscreen titles, and risk destabilising the host.

Until then, a side-car monitor (`macmon` / Stats) alongside the Metal HUD covers the same
need without touching the game's render path.
