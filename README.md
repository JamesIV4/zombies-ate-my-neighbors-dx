# Zombies Ate My Neighbors DX

This emulator-only mod for the USA SNES release adds:

- 50% larger sprite interaction hitboxes, from 16x16 to 24x24 pixels.
- Analog movement speed and 360-degree stick selection on the left stick.
- Independent right-stick aiming and firing in the game's eight native shot
  directions.

It also bundles optional ROM patches you can mix in from the
launcher's `Configure ROM Patches` screen: 
- **Bloody Disgusting Edition**
([hack #4306](https://www.romhacking.net/hacks/4306/)): restores the
censored red blood on the Game Over screen
- **Reverse Inventory Cycling**
([hack #4318](https://www.romhacking.net/hacks/4318/)): lets you cycle
weapons and items in both directions and enables a reworked control layout

The ROM patch retains the original wall collision, enemy, item, camera, tile,
and weapon code. The controller layer translates analog input into per-frame
movement deltas and writes them, plus the requested aim direction, to reserved
upper WRAM. Small ROM hooks apply movement before the original collision and
coordinate commit logic, and aiming immediately before the firing logic.

## Gameplay Video

[![Zombies Ate My Neighbors DX](https://img.youtube.com/vi/F1pOwoPr5Lw/0.jpg)](https://www.youtube.com/watch?v=F1pOwoPr5Lw)

## Quick Start

Download and extract the Windows x64 release ZIP, then run:

```text
ZAMN-DX.exe
```

The launcher will:

1. Open a dedicated mod launcher before starting the emulator.
2. Let you play, configure and test the controller, or quit.
3. Ask for your legally obtained USA ROM on the first play.
4. Verify and patch the ROM without requiring Python or external tools.
5. Start the bundled BizHawk runtime in a clean, chromeless full-screen window.

If the source ROM is not beside the launcher, a file picker will ask for it.
The generated patched ROM, controller profile, and Lua runtime configuration
are stored under `%LOCALAPPDATA%\ZAMNDX`; no administrator access is needed.
The release never downloads or distributes the game ROM itself.

## Requirements

- 64-bit Windows.
- The headerless USA ROM:
  `Zombies Ate My Neighbors (USA).sfc`
- An XInput-compatible dual-stick controller.

The release ZIP includes the self-contained launcher, .NET runtime, BizHawk
2.11.1, the app-local Microsoft Visual C++ runtime, the DX IPS patch, the
optional ROM patches, and the Lua controller runtime. Players do not need to install an emulator, .NET,
PowerShell, Python, the Visual C++ Redistributable, or any other dependency.

The expected source ROM SHA-256 is:

```text
b27e2e957fa760f4f483e2af30e03062034a6c0066984f2e284cc2cb430b2059
```

## Development Build

Python 3 is only required to rebuild the ROM patch:

```powershell
python tools/build.py
```

This creates:

- `dist/Zombies Ate My Neighbors DX.sfc`
- `dist/zamndx.ips`

The IPS file contains the hitbox changes, analog movement hook, right-stick
aim hook, and SNES checksum changes. Raw analog input is provided at runtime
because an SNES ROM has no way to read a modern host controller's axes.

Build the complete unsigned Windows release with:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_release.ps1
```

The release builder downloads a portable official .NET SDK and the official
BizHawk archive into the ignored `.tools` directory, publishes the
self-contained EXE, copies the Visual C++ app-local runtime from an installed
Visual Studio C++ workload, includes third-party license notices, and creates:

```text
dist/ZAMN-DX-Windows-x64-v1.0.0.zip
```

### Signed Releases

The signed-release workflow rebuilds the IPS patch and C# launcher, runs the
launcher tests, publishes the self-contained EXE, Authenticode-signs and
verifies it, then creates the ZIP and a `.sha256` checksum file.

Configure a trusted code-signing PFX once:

```powershell
.\setup-signing.ps1 -PfxPath "C:\path\certificate.pfx"
```

The PFX password is requested interactively and is never saved. Only the
installed certificate's public thumbprint is stored under the ignored
`.tools` directory.

Create future signed releases with one command:

```powershell
.\build-signed-release.ps1 -Version 1.0.1
```

The script refuses to emit a signed release if the certificate is missing,
expired, lacks its private key, the timestamp fails, or Authenticode
verification fails. Timestamping is bounded to two minutes by default, so a
timestamp service outage cannot hang the build indefinitely. The release
includes `release-manifest.json`,
`SHA256SUMS.txt`, and a checksum beside the final ZIP.

Unsigned builds may still trigger Windows SmartScreen. Authenticode signing
requires a trusted certificate issued for code signing; a self-signed
certificate does not establish public trust.

## Run

The launcher is the recommended way to run the mod. It opens before BizHawk
and presents four actions:

- `Play Game` starts BizHawk in full screen, hides its Lua utility window, and
  transfers controller focus to the game automatically.
- `Configure Controller` opens controller selection, live testing, deadzone,
  inversion, and input assignment.
- `Configure ROM Patches` toggles the optional improvements that are stacked on
  top of the DX core patch.
- `Quit` closes the launcher.

The main window shows which optional patches are currently active beneath the
feature card.

## Optional ROM Patches

The DX core patch is always applied. Optional improvements are listed under
`Configure ROM Patches` and can be turned on or off independently; the new
selection is applied the next time you press `Play Game`.

| Patch                     | Default | Description                                                                                                                                                                                                                                  |
| ------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bloody Disgusting Edition | On      | Restores censored red blood on the Game Over screen ([romhacking.net hack #4306](https://www.romhacking.net/hacks/4306/)). Edits only the blood-drip sprite tiles, so the purple transformation monster and other graphics stay untouched. |
| Reverse Inventory Cycling | On      | Cycle weapons and items in both directions ([romhacking.net hack #4318](https://www.romhacking.net/hacks/4318/)). Enables the reworked control scheme below (configurable).                                                                               |
| Battery Save              | On      | Saves level/ammo/item progress to SRAM after every level ([romhacking.net hack #7312](https://www.romhacking.net/hacks/7312/)). Load from the password screen with Start. Start a new game first - loading with no save shows a black screen. |

### Control schemes

The `Configure Controller` screen always matches the patch selection. With
Reverse Inventory Cycling **off**, the stock layout is used; with it **on**, a
reworked layout is used (configurable):

| Control            | Stock (patch off) | Reworked (patch on)  |
| ------------------ | ----------------- | ---------------------- |
| Left stick / D-pad | Move and aim      | Move and aim           |
| Right stick        | Aim and fire      | Aim and fire           |
| X (west)           | Fire weapon       | Fire weapon            |
| A (south)          | Change weapon     | Fire weapon            |
| B (east)           | Change item       | Radar / Map            |
| Y (north)          | Use item          | Use item               |
| LT / RT            | —                 | Weapon previous / next |
| LB / RB            | Radar on/off      | Item previous / next   |
| Start              | Pause             | Pause                  |

The reworked scheme reuses the patch's built-in "hold L to reverse" modifier
through button combos (the left trigger and bumper press the cycle button plus
SNES L), so the bundled patch is applied unmodified. Every control above is
re-bindable in `Configure Controller`.

The launcher rebuilds the patched ROM whenever your selection changes. It first
applies the DX core patch and verifies it against the published DX hash, then
stacks each enabled optional patch (verifying its integrity hash) and recomputes
the SNES checksum (correctly mirroring the trailing region when the Battery Save
patch grows the ROM to a non-power-of-two size). The active selection and the
resulting ROM hash are recorded in `%LOCALAPPDATA%\ZAMNDX\Games\patched.json`,
and your toggles are saved in `%LOCALAPPDATA%\ZAMNDX\patches.json`.

With Battery Save enabled the launcher also configures BizHawk to flush SaveRAM
periodically, so end-of-level saves are written to the `.srm` file even on an
unclean exit. Start a new game before trying to load.

Bundled optional patches are third-party hacks redistributed for convenience;
see `mod\bloody-disgusting.txt` for the source and attribution.

To assign an input, click `Capture`, release all controls, then press the
desired button or move the desired stick axis. Capture is performed directly
through Windows XInput rather than through the emulator. Click `Save` when
finished.

BizHawk controller bindings are optional because the runtime reads the host
controller directly. Normal BizHawk keyboard and controller bindings can
remain enabled.

The launcher uses a dedicated BizHawk configuration under
`%LOCALAPPDATA%\ZAMNDX\BizHawk`. Its first-run onboarding and update prompt are
disabled because controller setup and launching are handled by `ZAMN-DX.exe`.

Default controls:

- Left stick: move, with speed based on stick magnitude.
- Right stick: aim and continuously use the readied weapon.
- D-pad and all original SNES buttons remain available.

BizHawk normally names XInput axes `X1 LeftThumbX Axis` and similar. Controllers
in XInput slots X1 through X4 can be configured entirely through the launcher.
The launcher stores the user profile under `%LOCALAPPDATA%\ZAMNDX` and
generates its Lua runtime profile there.

The Lua runtime has no in-game overlay or configuration window. It releases
all overrides at startup and only overrides controls that are actively mapped.

## Technical Notes

The original collision routine at SNES address `$80:BEF1` compares both axis
deltas against a radius of 8 and a width of 16. The builder changes those
constants to 12 and 24, exactly 150% of the original dimensions. This is the
game's shared sprite collision path, so the larger bounds apply consistently
to enemies, pickups, projectiles, and player contact. Tile and wall collision
remain unchanged.

The analog layer uses independent fractional accumulators for X and Y. It
quantizes a constant-speed analog vector into small integer deltas, avoiding
the original engine's incompatible cardinal and diagonal movement cadences.
Those deltas enter the original tentative-position routine, so wall collision,
the committed player position, camera tracking, tile streaming, and sprites
all consume the same coordinates. Right-stick shots are selected from the
eight trajectories implemented by the original weapon engine; arbitrary
sub-direction projectile trajectories would require replacing every weapon's
movement logic. The controller mailbox uses `$7F:FFF0-$7F:FFF9`, well above
the original game's low-WRAM working area.

Mesen is useful for tracing and deterministic verification of the ROM patch,
but BizHawk is the runtime target because its Lua API exposes raw host
controller axes and frame-by-frame SNES input overrides.
