---
name: twin-stick-trigger-naming-unverified
description: The Reverse Cycling twin-stick scheme binds LT/RT, but BizHawk's runtime trigger naming is unverified
metadata:
  type: project
---

The Reverse Inventory Cycling control scheme (added 2026-06-16) puts weapon
cycling on the controller triggers (LT/RT). The launcher captures triggers fine
via raw XInput ("LeftTrigger"/"RightTrigger"), but at runtime the Lua reads
BizHawk's `input.get()` / `input.get_pressed_axes()`, and BizHawk's exact name
for an XInput trigger was not confirmed against a running emulator.

`mod/zamndx.lua` `augment_triggers()` hedges by marking the trigger "button"
pressed when any pressed-axis name contains "<device> ...LeftTrigger/RightTrigger"
with magnitude > 30. If LT/RT do nothing in-game, this is the first place to
check — adjust the axis-name match or threshold to BizHawk's real trigger axis
name/scale. Everything else (button combos, the `B`+`L` reverse modifier) is
unit-tested in [[.]] via `ModRuntime.BuildButtonMap`.
