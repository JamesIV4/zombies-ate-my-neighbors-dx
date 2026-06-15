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

1. Open a dedicated mod launcher before starting the emulator.
2. Let you play, configure and test the controller, or quit.
3. Verify and patch the source ROM without requiring Python.
4. Download the latest official Windows BizHawk release on first run, after
   asking permission.
5. Start the patched game in a clean, chromeless full-screen window.

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

The launcher is the recommended way to run the mod. It opens before BizHawk
and presents three actions:

- `Play Game` starts BizHawk in full screen and hides its Lua utility window.
- `Configure Controller` opens controller selection, live testing, deadzone,
  inversion, and input assignment.
- `Quit` closes the launcher.

To assign an input, click `Capture`, release all controls, then press the
desired button or move the desired stick axis. Capture is performed directly
through Windows XInput rather than through the emulator. Click `Save` when
finished.

BizHawk controller bindings are optional because the runtime reads the host
controller directly. Normal BizHawk keyboard and controller bindings can
remain enabled.

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
in XInput slots X1 through X4 can be configured entirely through the launcher.
The launcher stores the user profile under `%LOCALAPPDATA%\ZAMNDX` and
generates `mod/zamndx-controller-config.lua` for the runtime.

The Lua runtime has no in-game overlay or configuration window. It releases
all overrides at startup and only overrides controls that are actively mapped.

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
