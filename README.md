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

### Steam (macOS) — bundle wrapper

macOS Steam **cannot pass environment variables through launch options**: it treats the
first token of `%command%` as the program path, so both `VAR=value … %command%` and a
`wrapper.sh %command%` form fail with *"failed to start process … os error 260"*
([Valve issue #5548](https://github.com/ValveSoftware/steam-for-linux/issues/5548)).

The reliable method is to wrap the game's bundle executable. The installer does it for you,
reversibly:

```sh
make build
scripts/install-bundle-wrapper.sh install "/path/Game.app" 80   # cap 80; default if omitted
```

It renames `Contents/MacOS/<exe>` to `<exe>.framelimiter-orig` and drops in a small wrapper
that sets the environment and execs the original. Then **clear the game's Steam launch
options** and launch normally. To revert (or before reporting a game bug):

```sh
scripts/install-bundle-wrapper.sh uninstall "/path/Game.app"
```

A game update re-downloads the original executable and removes the wrapper — just re-run
`install` afterwards. The Metal HUD confirms the cap; the limiter also logs via `os_log`:

```sh
log stream --style compact --predicate 'eventMessage CONTAINS "framelimiter"'
```

> On **Linux** Steam, environment variables in launch options work directly:
> `DYLD_INSERT_LIBRARIES=… FRAME_LIMIT_FPS=80 %command%`. `scripts/steam-launch.sh` is a
> wrapper for that case and for launching outside Steam.

### Any app

```sh
DYLD_INSERT_LIBRARIES=/abs/path/build/frame_limiter.dylib FRAME_LIMIT_FPS=80 \
  "/path/to/Game.app/Contents/MacOS/Game"
```

## Runtime control (enable / disable / change the cap)

The cap is held in a control file the injected dylib watches, so you change it while the
game runs — no restart. `scripts/flctl` is a thin front-end (the Steam wrapper points
`FRAME_LIMIT_FILE` at `~/.framelimiter.fps`):

```sh
scripts/flctl 30        # cap to 30 fps
scripts/flctl off       # disable — the game free-runs again (cap = 0)
scripts/flctl on        # re-enable at the last cap
scripts/flctl toggle    # flip off <-> last cap
scripts/flctl status    # show the current target
```

Equivalently, just write the file: `echo 30 > ~/.framelimiter.fps` (and `echo 0` to
disable). With `FRAME_LIMIT_SIGNALS=1`, `SIGUSR1`/`SIGUSR2` sent to the game step the
target by 5 fps.

### Hotkeys

There's no in-process hotkey (an injected dylib can't reliably grab global keys without
accessibility permissions, and games consume input themselves). Instead bind a system
hotkey to `flctl` with any hotkey tool. Example with [Hammerspoon](https://www.hammerspoon.org):

```lua
local fl = "/Users/aatricks/Documents/Dev/FrameLimiter/scripts/flctl"
hs.hotkey.bind({"cmd","alt"}, "L", function() hs.execute(fl.." toggle", true) end)  -- on/off
hs.hotkey.bind({"cmd","alt"}, "[", function() hs.execute(fl.." 30", true) end)
hs.hotkey.bind({"cmd","alt"}, "]", function() hs.execute(fl.." 80", true) end)
```

(Karabiner-Elements, BetterTouchTool, or a macOS Shortcut running a shell line work too.)

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

## Which games work

It works with **native macOS games that render through Metal** — i.e. that present via a
`CAMetalLayer`. That's essentially every modern native Mac game, whether it uses Metal
directly, MetalKit/`MTKView`, or SDL2 / MoltenVK (MoltenVK also presents through a
`CAMetalLayer`). Install per game by running `install-bundle-wrapper.sh` on that game's
`.app`.

It does **not** apply to:

- **Non-native games** run through Wine / CrossOver / Whisky / Game Porting Toolkit — those
  are Windows binaries under translation, with a different present path.
- **Hardened + notarized** binaries, until re-signed (run `check-target.sh`; it tells you).
  Many Steam games — like Hades II — ship ad-hoc signed and need no re-sign.
- **Anti-cheat** titles (EAC/BattlEye) — injection will be flagged. Single-player only.
- **OpenGL-only** games (rare on current macOS) — no `CAMetalLayer` to hook.

And remember it only caps *downward*: a game already running at or below your target, or one
that hard-caps its own frame rate, won't change.

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
