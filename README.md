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

## Requirements

- The headerless USA ROM:
  `Zombies Ate My Neighbors (USA).sfc`
- Python 3 to build the patch.
- [BizHawk 2.11.1 or newer](https://github.com/TASEmulators/BizHawk/releases)
  to run the analog controller layer.
- An XInput-compatible dual-stick controller, or equivalent axes exposed by
  BizHawk.

The expected source ROM SHA-256 is:

```text
b27e2e957fa760f4f483e2af30e03062034a6c0066984f2e284cc2cb430b2059
```

## Build

From the repository root:

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

1. Open the patched ROM in BizHawk.
2. Configure a normal SNES controller for player 1.
3. Open `Tools > Lua Console`.
4. Load `mod/zamndx.lua`.
5. Move each analog stick once so the script can identify its axes.

If EmuHawk exits while starting its SNES core, launch it with `--gdi`. That
renderer was required on the development machine:

```powershell
EmuHawk.exe --gdi --lua "path\to\mod\zamndx.lua" "path\to\dist\Zombies Ate My Neighbors DX.sfc"
```

Default controls:

- Left stick: move, with speed based on stick magnitude.
- Right stick: aim and continuously use the readied weapon.
- D-pad and all original SNES buttons remain available.

BizHawk normally names XInput axes `X1 LeftThumbX Axis` and similar. If a
controller uses different names, edit the four axis overrides near the top of
`mod/zamndx.lua`. Y-axis inversion defaults to BizHawk's SDL convention and is
configurable there as well.

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
