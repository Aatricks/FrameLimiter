# FrameLimiter

A frame rate limiter for native Metal games on macOS (Apple Silicon). It injects as a dynamic library (`DYLD_INSERT_LIBRARIES`) to cap a game's frame rate to a configurable, live-tunable target, independent of VSync.

This is intended for fanless Apple Silicon laptops, where rendering frames beyond the display's refresh rate (or what the game needs) wastes battery and generates heat.

## How it works

The limiter hooks `-[CAMetalLayer nextDrawable]` (the core call games use to request framebuffers) and inserts a calculated delay using `mach_wait_until` to pace the render loop. 

Unlike simple display presentation delays, delaying `nextDrawable` creates back-pressure in the render pipeline. This causes the game engine to stall naturally, lowering GPU utilization and saving power.

- **Zero busy-waiting**: It sleeps rather than spins to conserve energy.
- **Adaptive VSync**: If the target frame rate is set above the display refresh rate, the library turns off the layer's VSync (`displaySyncEnabled`) to minimize input latency (at the cost of screen tearing). At or below the refresh rate, the game's original VSync setting is respected.

When the game is moved to another Space or alt-tabbed, the limiter drops to `FRAME_LIMIT_BG_FPS` (default 10) and stops suppressing App Nap, then restores the foreground cap when you switch back.

## Building

To build the library:

```bash
make build
```

This compiles:
- `build/frame_limiter.dylib` (ad-hoc signed for Apple Silicon compatibility)
- `build/minimal_metal_app` (a test harness)
- `build/FrameLimiter.app` (menu-bar agent)

## Usage

### 1. Steam & Native Games (Wrapper Binary Method)
Steam on macOS cannot pass environment variables through launch options, and using `%command%` wrapper scripts fails with an OS execution error (Valve issue #5548).

To get around this, the `install-lsenv.sh` script replaces the game's executable with a compiled C wrapper that sets the required environment variables before launching the real game (renamed to `Executable.real`). 

By compiling a binary wrapper and copying the original game's entitlements, macOS still recognizes the app identity, ensuring **Game Mode** and fullscreen compositor bypass optimizations remain active.

```bash
# Install (replaces the game executable with the C wrapper; defaults to 80 fps if FPS is omitted)
./scripts/install-lsenv.sh install "/path/to/Game.app" 80

# Uninstall (restores the original executable and plist backups)
./scripts/install-lsenv.sh uninstall "/path/to/Game.app"

# Status (shows whether a game is injected)
./scripts/install-lsenv.sh status "/path/to/Game.app"

# CLI tool setup (symlinks flctl into ~/.local/bin)
./scripts/install-lsenv.sh cli

# Clean (removes the shared dylib, all control files, and the flctl symlink)
./scripts/install-lsenv.sh clean
```

*Note: Game updates through Steam or the App Store will overwrite the wrapper executable. You will need to re-run the install script after any game update. This is SAFE to re-run: it detects whether the on-disk binary is the wrapper or a fresh game binary and never clobbers the real binary. A failed install rolls back to a launchable executable.*

*The dylib is published to a STABLE path (`~/.framelimiter/frame_limiter.dylib`) baked into the wrapper, so moving, rebuilding, or deleting this repo no longer orphans an installed game. Per-app uninstall only reverts that bundle; control files and the shared dylib persist (other installed games keep working) until you run the `clean` command.*

### 2. Standalone Games (Direct Command Line)
For standalone apps launched outside of Steam, you can run them directly from the terminal with the environment variables pre-set:

```bash
DYLD_INSERT_LIBRARIES=/Users/aatricks/Documents/Dev/FrameLimiter/build/frame_limiter.dylib \
FRAME_LIMIT_FILE=$HOME/.framelimiter.fps \
FRAME_LIMIT_FPS=80 \
"/path/to/Game.app/Contents/MacOS/Game"
```

## Runtime Tuning

The frame rate cap can be changed instantly **on the fly** without restarting the game. However, toggling the Metal HUD requires **restarting the game**, as macOS only checks the HUD environment variable at startup.

Use the `flctl` tool to control these settings:

```bash
./scripts/flctl 30          # Cap to 30 fps (takes effect immediately, clamped to 1000)
./scripts/flctl off         # Disable the cap (takes effect immediately)
./scripts/flctl on          # Restore the last active cap (takes effect immediately)
./scripts/flctl toggle      # Toggle the cap on/off (takes effect immediately)
./scripts/flctl hud off     # Hide the Metal HUD overlay (requires game restart)
./scripts/flctl hud on      # Show the Metal HUD overlay (requires game restart)
./scripts/flctl hud         # Show current HUD status
./scripts/flctl bgfps 10    # Cap to 10 fps when not visible (requires game restart)
./scripts/flctl bgfps off   # Don't throttle when backgrounded
./scripts/flctl bgfps       # Show current background fps cap
./scripts/flctl status      # Show attach-aware status (whether game is injected and live fps)
./scripts/flctl -h          # Show help message
```

### Menu-bar app
The repository builds a lightweight macOS menu-bar agent (no Dock icon) that shows the live measured fps of the active game. 
You can use it to pick a frame cap, set the background cap, toggle the Metal HUD, and open the log — all via the same control files that `flctl` uses.
- Launch with `open build/FrameLimiter.app` (or add it to your Login Items).
- Note: HUD and background-cap changes applied through the menu-bar app only take effect on the next game launch.
- **Games submenu**: discover and manage games without the terminal. It auto-detects Steam games (scanning `steamapps/common` across all library folders) and lets you **"Add game…"** for anything else (remembered across launches). A checkmark shows which games have the limiter installed; clicking a game **installs or uninstalls** it (it shells out to `install-lsenv.sh`, so it's the same safe operation). Quit the game first — the app will prompt if it's still running. Requires running the app from the repo's `build/` (it locates `install-lsenv.sh` and the dylib relative to itself).

### Control files
The limiter state is managed via the following control files. `flctl`, the menu-bar app, and the wrapper binary all interact with these:

| File | Description |
|---|---|
| `~/.framelimiter.fps` | Live FPS target (single integer; `0` = off). The dylib watches it (250 ms poll). This is a **persistent source of truth** across launches; the installer seeds it with the default ONLY if it does not already exist, so a prior `flctl off` is respected on the next launch. |
| `~/.framelimiter.fps.last` | Last non-zero cap (used by `flctl on` and `toggle`). |
| `~/.framelimiter.hud` | Metal HUD on/off (`1`/`0`); read by the launcher at startup, applies on the **next launch** only. |
| `~/.framelimiter.bgfps` | Background/occluded FPS cap; read at launch, applies on the **next launch**. |
| `~/.framelimiter.status` | **Read-only heartbeat** written ~1x/second by the dylib; contains key=value lines (`pid`, `target`, `fg_target`, `measured_fps`, `background`, `bg_fps`, `refresh`, `vsync_mode`, `ts`). A reader treats the limiter as live when `ts` is within ~3 s of now. |
| `~/.framelimiter.log` | Appended log output (tail it, or use: `log stream --predicate 'eventMessage CONTAINS "framelimiter"'`). |

### Hotkeys via Hammerspoon
You can bind `flctl` to system-wide shortcuts. For example, in Hammerspoon:

```lua
local fl = "/Users/aatricks/Documents/Dev/FrameLimiter/scripts/flctl"
hs.hotkey.bind({"cmd","alt"}, "L", function() hs.execute(fl.." toggle", true) end)
hs.hotkey.bind({"cmd","alt"}, "[", function() hs.execute(fl.." 30", true) end)
hs.hotkey.bind({"cmd","alt"}, "]", function() hs.execute(fl.." 80", true) end)
```

## Recommended Targets (60Hz Displays)

On fixed 60Hz displays (like most fanless MacBooks):
- **Below 60 FPS**: Stick to integer divisors of 60 (**30, 20, or 15 fps**) to prevent judder. Frame rates like 40 or 45 will stutter because frames won't line up with the display's refresh cycles.
- **At 60 FPS**: Matches the display refresh while saving power.
- **Above 60 FPS (e.g. 80)**: Lowers input latency, but requires VSync to be disabled (handled automatically) which causes tearing.

## Environment Variables

Configure behavior by setting these before launching:

| Variable | Default | Description |
|---|---|---|
| `FRAME_LIMIT_FPS` | *unset* | Target FPS. Unset or `0` disables the limiter. |
| `FRAME_LIMIT_FILE` | `$HOME/.framelimiter.fps` | Control file to watch for runtime changes. |
| `FRAME_LIMIT_LOGFILE` | *unset* | Append the log to this file (the wrapper sets `~/.framelimiter.log`). |
| `FRAME_LIMIT_STATUS_FILE` | `$HOME/.framelimiter.status` | Path of the heartbeat/status file. |
| `FRAME_LIMIT_REFRESH` | *auto-detected* | Screen refresh rate (Hz) for VSync switching. Auto-detected from the main display when unset, and re-detected on display reconfiguration. Set it only to pin a value manually. |
| `FRAME_LIMIT_VSYNC` | `-1` | `-1` auto (default), `0` force VSync off, `1` force VSync on. |
| `FRAME_LIMIT_BG_FPS` | `10` | FPS cap applied while the game is occluded / on another Space / not the active app. `0` disables background throttling entirely. While backgrounded the limiter also releases its App Nap assertion so macOS can throttle the process. |
| `FRAME_LIMIT_LOG` | `0` | `1` to log periodic FPS; `2` for per-frame timing details. |
| `FRAME_LIMIT_SIGNALS` | `0` | Set `1` to enable `SIGUSR1`/`SIGUSR2` target stepping (+/- 5 fps). |
| `FRAME_LIMIT_QOS` | `1` | Forces user-interactive QoS on the render thread. |
| `FRAME_LIMIT_NONAP` | `1` | Disables macOS App Nap throttling for the game process. |
| `MTL_HUD_ENABLED` | `1` | macOS native Metal HUD overlay toggle. Set to `0` to hide it. |

## Code Signing & Hardened Runtime

If a game runs with a **Hardened Runtime** or enforces **Library Validation**, macOS will ignore `DYLD_INSERT_LIBRARIES`.

Check the game's executable:
```bash
./scripts/check-target.sh "/path/to/Game.app/Contents/MacOS/Game"
```

If it has a hardened runtime, you can re-sign it locally with validation disabled:

1. Extract current entitlements:
   ```bash
   codesign -d --entitlements ents.plist "/path/to/Game.app/Contents/MacOS/Game"
   ```
2. Add these keys to `ents.plist`:
   ```xml
   <key>com.apple.security.cs.disable-library-validation</key>
   <true/>
   <key>com.apple.security.cs.allow-dyld-environment-variables</key>
   <true/>
   ```
3. Re-sign the app:
   ```bash
   codesign -f -s - --options runtime --entitlements ents.plist "/path/to/Game.app"
   xattr -dr com.apple.quarantine "/path/to/Game.app"
   ```

## Compatibility

- **Anti-Cheat**: Do not use on games with active anti-cheat (Easy Anti-Cheat, BattlEye, VAC). Dylib injection and re-signing will trigger bans.
- **Translation Layers**: Does not support games running via Wine, CrossOver, Whisky, or GPTK.
- **Metal Only**: Requires the game to render via `CAMetalLayer`. OpenGL games are not supported.

## Testing

Verify the limiter using the minimal test app:

```bash
# Headless test capped at 30 fps
make run-minimal FPS=30

# Windowed test capped at 80 fps with logging
WINDOWED=1 FRAME_LIMIT_LOG=1 ./scripts/run-minimal.sh 80
```

Keep the test window active for accurate timing; macOS throttles background processes.

## License

MIT
