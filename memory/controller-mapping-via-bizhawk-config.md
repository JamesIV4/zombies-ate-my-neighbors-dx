---
name: controller-mapping-via-bizhawk-config
description: Button mapping is written to BizHawk's config.ini, not the Lua; the Lua only does analog movement + aim
metadata:
  type: project
---

As of 2026-06-16 the controller button mapping is applied through BizHawk's own
controller config, not the Lua runtime. `ModRuntime.EnsureBizHawkConfig` writes
`AllTrollers -> "SNES Controller" -> "P1 <btn>"` from `BuildButtonMap(settings,
scheme)` (comma-separated host lists OR together, so a host under several SNES
buttons is a combo like LT = `P1 B` + `P1 L`). Unused buttons are set to "" so
BizHawk's default bindings (e.g. `X1 RightShoulder -> P1 R`, `X1 Back -> P1
Select`) cannot leak through — that leak was the original cause of "RB/Select
toggle the map."

`mod/zamndx.lua` now only overrides the movement direction (for facing) and the
aim/fire button (`Y`); everything else is BizHawk-native. BizHawk's trigger
control names are `X1 LeftTrigger` / `X1 RightTrigger` (confirmed in the bundled
`defctrl.json`), so triggers bind natively with no Lua axis bridge needed.
