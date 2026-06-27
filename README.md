# FrameLimiter

A frame rate limiter for native Metal games on macOS (Apple Silicon). It injects as a dynamic library (`DYLD_INSERT_LIBRARIES`) to cap a game's frame rate to a configurable, live-tunable target, independent of VSync.

This is intended for fanless Apple Silicon laptops, where rendering frames beyond the display's refresh rate (or what the game needs) wastes battery and generates heat.

## How it works

The limiter hooks `-[CAMetalLayer nextDrawable]` (the core call games use to request framebuffers) and inserts a calculated delay using `mach_wait_until` to pace the render loop. 

Unlike simple display presentation delays, delaying `nextDrawable` creates back-pressure in the render pipeline. This causes the game engine to stall naturally, lowering GPU utilization and saving power.

- **Zero busy-waiting**: It sleeps rather than spins to conserve energy.
- **Adaptive VSync**: If the target frame rate is set above the display refresh rate, the library turns off the layer's VSync (`displaySyncEnabled`) to minimize input latency (at the cost of screen tearing). At or below the refresh rate, the game's original VSync setting is respected.

## Building

To build the library:

```bash
make build
```

This compiles:
- `build/frame_limiter.dylib` (ad-hoc signed for Apple Silicon compatibility)
- `build/minimal_metal_app` (a test harness)

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
```

*Note: Game updates through Steam or the App Store will overwrite the wrapper executable. You will need to re-run the install script after any game update.*

### 2. Standalone Games (Direct Command Line)
For standalone apps launched outside of Steam, you can run them directly from the terminal with the environment variables pre-set:

```bash
DYLD_INSERT_LIBRARIES=/Users/aatricks/Documents/Dev/FrameLimiter/build/frame_limiter.dylib \
FRAME_LIMIT_FPS=80 \
"/path/to/Game.app/Contents/MacOS/Game"
```

## Runtime Tuning

The frame rate cap can be changed instantly **on the fly** without restarting the game. However, toggling the Metal HUD requires **restarting the game**, as macOS only checks the HUD environment variable at startup.

Use the `flctl` tool to control these settings (saved to `~/.framelimiter.fps` and `~/.framelimiter.hud` respectively):

```bash
./scripts/flctl 30          # Cap to 30 fps (takes effect immediately)
./scripts/flctl off         # Disable the cap (takes effect immediately)
./scripts/flctl on          # Restore the last active cap (takes effect immediately)
./scripts/flctl toggle      # Toggle the cap on/off (takes effect immediately)
./scripts/flctl hud off     # Hide the Metal HUD overlay (requires game restart)
./scripts/flctl hud on      # Show the Metal HUD overlay (requires game restart)
./scripts/flctl status      # Show current status (fps cap and HUD state)
```

Or write to the files directly:
```bash
# Set target frame rate
echo 30 > ~/.framelimiter.fps

# Show/hide Metal HUD
echo 0 > ~/.framelimiter.hud  # Hide
echo 1 > ~/.framelimiter.hud  # Show
```

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
| `FRAME_LIMIT_FILE` | `$TMPDIR/framelimiter.fps` | Control file to watch for runtime changes. |
| `FRAME_LIMIT_REFRESH` | `60` | Screen refresh rate (Hz) for VSync switching. |
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
