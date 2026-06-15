# Zombies Ate My Neighbors DX

This emulator-only mod for the USA SNES release adds:

- 50% larger sprite interaction hitboxes, from 16x16 to 24x24 pixels.
- Analog movement speed and 360-degree stick selection on the left stick.
- Independent right-stick aiming and firing in the game's eight native shot
  directions.

The ROM patch retains the original movement, wall collision, enemy, item, and
weapon code. The controller layer translates analog input into native SNES
inputs and writes the requested aim direction to reserved upper WRAM. A small
ROM hook applies that direction immediately before the original firing logic
reads it.

## Quick Start

On Windows, double-click:

```text
Play ZAMN DX.cmd
```

The launcher will:

1. Verify and patch the source ROM without requiring Python.
2. Download the latest official Windows BizHawk release on first run, after
   asking permission.
3. Start BizHawk with the patched ROM, analog controls, twin-stick aiming, and
   the compatible GDI renderer.
4. Open the controller setup and live-test window automatically.

If the source ROM is not beside the launcher, a file picker will ask for it.
BizHawk is installed per-user under `%LOCALAPPDATA%\ZAMNDX\BizHawk`; no
administrator access is needed. The launcher never downloads or distributes
the game ROM itself.

## Requirements

- The headerless USA ROM:
  `Zombies Ate My Neighbors (USA).sfc`
- [BizHawk 2.11.1 or newer](https://github.com/TASEmulators/BizHawk/releases)
  to run the analog controller layer. The launcher can install it.
- An XInput-compatible dual-stick controller, or equivalent axes exposed by
  BizHawk.

The expected source ROM SHA-256 is:

```text
b27e2e957fa760f4f483e2af30e03062034a6c0066984f2e284cc2cb430b2059
```

## Build

The launcher applies `dist/zamndx.ips` itself. Python 3 is only required for
development or rebuilding the IPS:

```powershell
python tools/build.py
```

This creates:

- `dist/Zombies Ate My Neighbors DX.sfc`
- `dist/zamndx.ips`

The IPS file contains the hitbox changes, right-stick aim hook, and SNES
checksum changes. Analog input is provided at runtime because an SNES ROM has
no way to read a modern host controller's raw axes.

## Run

The launcher is the recommended way to run the mod. BizHawk controller
bindings are optional because the controller layer reads the host controller
directly. Normal BizHawk keyboard and controller bindings can remain enabled.

In `ZAMN DX Controller Setup`:

1. Select the host device. `X1` is the default for the first XInput controller.
2. Move both sticks and press buttons. The live-test fields should update
   immediately.
3. Use `Capture` beside any axis or SNES button that needs a different binding.
4. Click `Save` to reuse the configuration on future launches.

`Release inputs` immediately clears every Lua input override. This is useful
when testing mappings or recovering from a stale script instance.

To run without the launcher, open the patched ROM in BizHawk, then load
`mod/zamndx.lua` from `Tools > Lua Console`.

If EmuHawk exits while starting its SNES core, launch it with `--gdi`. That
renderer was required on the development machine:

```powershell
EmuHawk.exe --gdi --lua "path\to\mod\zamndx.lua" "path\to\dist\Zombies Ate My Neighbors DX.sfc"
```

Default controls:

- Left stick: move, with speed based on stick magnitude.
- Right stick: aim and continuously use the readied weapon.
- D-pad and all original SNES buttons remain available.

BizHawk normally names XInput axes `X1 LeftThumbX Axis` and similar. Controllers
with different names can be configured entirely through the setup window.
Configuration is saved as `mod/zamndx-controller-config.lua`.

If a previously running version left all controls unresponsive, close that
BizHawk instance and relaunch through `Play ZAMN DX.cmd`. The current
controller layer releases all overrides at startup and only overrides controls
that are actively mapped.

## Technical Notes

The original collision routine at SNES address `$80:BEF1` compares both axis
deltas against a radius of 8 and a width of 16. The builder changes those
constants to 12 and 24, exactly 150% of the original dimensions. This is the
game's shared sprite collision path, so the larger bounds apply consistently
to enemies, pickups, projectiles, and player contact. Tile and wall collision
remain unchanged.

The analog layer uses temporal interpolation between adjacent native movement
directions. This preserves the game's collision response while allowing any
left-stick angle and partial-stick speed. Right-stick shots are selected from
the eight trajectories implemented by the original weapon engine; arbitrary
sub-direction projectile trajectories would require replacing every weapon's
movement logic. The aim mailbox uses `$7F:FFF0-$7F:FFF3`, well above the
original game's low-WRAM working area.

Mesen is useful for tracing and deterministic verification of the ROM patch,
but BizHawk is the runtime target because its Lua API exposes raw host
controller axes and frame-by-frame SNES input overrides.
