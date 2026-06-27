# FrameLimiter

A small frame-rate limiter for **native Metal games on macOS** (Apple Silicon),
injected as a dylib via `DYLD_INSERT_LIBRARIES`. It caps a game's frame rate to a
configurable, **live-tunable** target — independent of the game's own VSync setting —
to trade input latency against GPU power and heat.

It's aimed at fanless Apple Silicon laptops, where rendering far above what the panel
can show (or above what the game needs) just wastes battery and generates heat for
frames you never see.

## How it works

- It swizzles `-[CAMetalLayer nextDrawable]` and paces the render loop with
  `mach_wait_until`.
- Pacing `nextDrawable` applies **back-pressure**: the in-flight drawable pool drains
  and the render thread stalls, so the GPU does *less real work* — it isn't merely
  delaying display.
- **Adaptive VSync**: if the target is above the display refresh, `displaySyncEnabled`
  is forced off so the engine can produce frames faster than the panel refreshes (this
  tears on a fixed-refresh panel — the accepted price of lower latency). At or below
  refresh, the layer's original VSync setting is restored.
- It **sleeps, never spins** — no busy-waiting, because the whole point is to save power.

A limiter can only cap *downward*. It cannot make a game render faster than it already
does; an above-refresh target only has an effect if the game actually produces that many
frames with VSync off.

## Requirements

- Apple Silicon Mac, current macOS.
- A native Metal target that presents through `CAMetalLayer` — which is essentially all
  of them, including games built on MetalKit/`MTKView` or SDL2's Metal backend.
- Xcode Command Line Tools (`clang`) to build.

## Build

```sh
make build           # -> build/frame_limiter.dylib  (ad-hoc signed)
```

Ad-hoc signing is mandatory: on Apple Silicon every loaded image must carry a valid
signature. `make build` does it for you.

## Usage

### Steam (macOS)

macOS Steam does **not** shell-parse launch options, so the Linux-style
`VAR=value … %command%` form fails to launch (`failed to start process … os error 260`).
Use the wrapper script as the launch command instead — in **Properties → Launch Options**:

```
"/abs/path/scripts/steam-launch.sh" %command%
```

The wrapper sets `DYLD_INSERT_LIBRARIES`, `FRAME_LIMIT_FPS` (default 80),
`FRAME_LIMIT_FILE` (`~/.framelimiter.fps`) and `MTL_HUD_ENABLED=1`, then execs the game.
Edit the script to change the default target. The Metal HUD confirms the cap; the limiter
also logs via `os_log`:

```sh
log stream --style compact --predicate 'eventMessage CONTAINS "framelimiter"'
```

On **Linux** Steam the env-prefix form works directly:
`DYLD_INSERT_LIBRARIES=… FRAME_LIMIT_FPS=80 %command%` (this project targets macOS, but the
mechanism is the same).

### Any app

```sh
DYLD_INSERT_LIBRARIES=/abs/path/build/frame_limiter.dylib FRAME_LIMIT_FPS=80 \
  "/path/to/Game.app/Contents/MacOS/Game"
```

## Live tuning

Change the cap while the game is running, no restart (the Steam wrapper points
`FRAME_LIMIT_FILE` at `~/.framelimiter.fps`):

```sh
echo 30 > ~/.framelimiter.fps     # path set by FRAME_LIMIT_FILE (default $TMPDIR/framelimiter.fps)
```

Or, with `FRAME_LIMIT_SIGNALS=1`, send `SIGUSR1` (step down) / `SIGUSR2` (step up) to the
game process to nudge the target by 5 fps.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `FRAME_LIMIT_FPS` | *(unset)* | Target fps. **Unset or `0` = no-op**: nothing is hooked. |
| `FRAME_LIMIT_FILE` | `$TMPDIR/framelimiter.fps` | Control file watched for live retuning. |
| `FRAME_LIMIT_REFRESH` | `60` | Display refresh (Hz) used as the adaptive-VSync threshold. Set to your panel's rate. |
| `FRAME_LIMIT_LOG` | `0` | `1` = periodic fps logging; `2` = per-frame pace/timing. |
| `FRAME_LIMIT_SIGNALS` | *(off)* | `1` = enable `SIGUSR1`/`SIGUSR2` stepping. Off by default so it can't clash with a game that uses those signals. |
| `FRAME_LIMIT_QOS` | `1` | Pin the render thread to user-interactive QoS for precise pacing. `0` disables. |
| `FRAME_LIMIT_NONAP` | `1` | Keep the host out of App Nap so paced sleeps aren't throttled. `0` disables. |

## Choosing a target on a fixed-refresh panel

Most Apple Silicon laptops have a **60 Hz fixed** internal panel (no ProMotion/VRR). That
shapes what targets make sense:

- **Below refresh** — only **divisors of 60 (30 / 20 / 15)** are judder-free, because each
  frame is shown for a whole number of refreshes. **30 fps** halves the frame count and is
  the best cool-and-quiet point. Non-divisors (45, 40, 58…) microjudder.
- **At refresh (60)** — the no-tearing baseline; useful to stop a game wasting power above
  what the panel shows.
- **Above refresh (e.g. 80)** — only meaningful with VSync off, which the limiter forces.
  It lowers input latency (each displayed frame was rendered more recently) at the cost of
  **tearing**. Only works if the game actually renders that fast.

## Code signing — when you do and don't need to re-sign

`DYLD_INSERT_LIBRARIES` is ignored only when the target has a **hardened runtime** without
the dyld-environment entitlement, or **library validation** rejects foreign dylibs. Many
games don't have either — they ship ad-hoc signed with library validation already disabled
and no hardened runtime, so injection works with **no changes to the game**.

Check any target:

```sh
scripts/check-target.sh "/path/to/Game.app/Contents/MacOS/Game"
```

If it reports a hardened runtime, re-sign it locally (this breaks notarization — fine for
local use — and is reverted by game updates):

```sh
codesign -d --entitlements ent.plist "$BIN"   # then add, in ent.plist:
#   com.apple.security.cs.disable-library-validation
#   com.apple.security.cs.allow-dyld-environment-variables
codesign -f -s - --options runtime --entitlements ent.plist "$APP"
xattr -dr com.apple.quarantine "$APP"
```

## Caveats

- **Tearing** above refresh is inherent on a fixed panel without VRR.
- **Anti-cheat**: dylib injection (and any re-signing) will trip EAC / BattlEye / VAC. Use
  only on single-player games.
- **External displays**: set `FRAME_LIMIT_REFRESH` to that display's refresh rate.
- If a game presents through several `CAMetalLayer`s, only the largest ("primary") layer is
  paced; overlays pass through untouched.

## Testing

`minimal_metal_app/` is a tiny native-Metal harness that drives `nextDrawable` in a loop
and logs its achieved fps, so the limiter can be exercised without a real game:

```sh
WINDOWED=1 FRAME_LIMIT_LOG=1 ./scripts/run-minimal.sh 80   # visible window, capped to 80
make run-minimal FPS=30                                    # headless, capped to 30
```

Keep the window foreground (or verify in a real game with `MTL_HUD_ENABLED=1`) for accurate
readings — macOS coalesces timers for backgrounded, window-less utility processes, which can
make the headless harness's fps noisy even though the limiter is pacing correctly.

See [docs/DESIGN.md](docs/DESIGN.md) for the recon, the hook-point rationale, and the risk
analysis.

## License

MIT — see [LICENSE](LICENSE).
