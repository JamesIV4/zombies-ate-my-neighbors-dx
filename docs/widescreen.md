# Widescreen (optional feature) — plan & progress

Status: **widescreen is integrated as a default-on optional ZAMN-DX extension.**
The ROM hook is Mesen-stable, including level-edge clamps and a gameplay-only
off-map black fill. `mesen_ws_verify.lua`, `mesen_offmap_black_verify.lua`, and
`mesen_black_fix_verify.lua` all pass with `failures=0`. The launcher now stacks
`mod/widescreen.ips` by default and starts BizHawk through the bundled repo-owned
`bsnes_hd_beta_zamndx_libretro.dll`, whose core-option defaults are patched for
ZAMN-DX widescreen. The build fills **10 strip columns per side** (about 80 px),
clamps the horizontal camera 8 tiles inside each edge, and paints true off-map
strip columns with an opaque black BG1 tile calibrated to gameplay palette/VRAM
(char base `$5000`, CGRAM `$08`, free tile `$27F`; see §6 bug 9). The gather is
incremental and now goes idle after post-scroll catch-up, so the steady-state
cost is much lower than the earlier full-refill attempt.

---

## 1. Goal

Add an **optional** widescreen mode that shows more of the level horizontally,
**without changing gameplay** — specifically without letting enemies activate or
aggro on neighbors earlier than they normally would. Ideally it auto-matches the
player's monitor aspect ratio.

## 2. Why this is hard (the core constraint)

The SNES PPU emits exactly **256 px per scanline**. A ROM hack alone cannot widen
the field of view — the extra pixels have to come from a renderer that fetches more
background and sprites. So widescreen has two parts:

1. **A renderer that draws past 256 px.** The only SNES option is **bsnes-hd**
   (`WideScreen Mode = all scenes`). It renders extra BG/sprite columns on each side.
2. **Correct content in those extra columns.** bsnes-hd reads VRAM; the game only
   streams BG tiles for the 256 px window, so the widescreen strips show **stale
   VRAM** (garbage on the leading edge). A small **ROM hack** must keep those strip
   columns filled from the level map.

The BG streaming and OAM X-cull pieces are **display-only**: bsnes-hd renders more
of the world the game already simulates. The item/neighbor work is the exception:
it intentionally widens the stock map-object and victim activation/deactivation X
gates so spawners can wake while still inside the widescreen side strips.

### POC result (user, in standalone bsnes-hd)
Loading **unpatched** ZAMN in bsnes-hd with widescreen + "render sprites anywhere":
- **Sprites:** render correctly in the strips. (The game culls them at the 256 edge;
  a later OAM-cull relax can show active sprites in the strips.)
- **HUD:** stays correctly in the 4:3 inner region. No work needed.
- **Background:** the one real problem — the leading strip shows stale tiles. **This
  is what the ROM hook fixes.**

## 3. Emulator hosting

The runtime target remains **BizHawk** because its Lua API drives analog movement
and right-stick aiming. BizHawk 2.11.1 can host libretro cores through its
OpenAdvanced path, and its command-line ROM argument accepts the serialized
OpenAdvanced string:

```text
*Libretro*{"Path":"...patched rom...","CorePath":"...bsnes_hd_beta_zamndx_libretro.dll"}
```

BizHawk's libretro bridge only exposes core-option **defaults** to the core; it
does not persist arbitrary libretro option overrides. To keep the release stable,
ZAMN-DX therefore ships a repo-owned patched copy of `bsnes_hd_beta_libretro.dll`
as `mod/bsnes_hd_beta_zamndx_libretro.dll`. The release builder copies that exact
binary into `runtime/BizHawk/Libretro/Cores/`.

The bundled core also applies `tools/bsnes_hd_libretro_wram.patch`. That patch
exposes SNES WRAM through libretro `RETRO_MEMORY_SYSTEM_RAM` and adds ZAMN-DX
startup/menu renderer guards for the reused tilemaps. BizHawk turns the WRAM
export into its `mainmemory` domain, allowing the existing Lua twin-stick runtime
to write the ZAMN-DX controller mailbox while widescreen is running through
bsnes-hd.

The renderer guards are keyed from live PPU layer bases and VRAM contents:

| Scene signature | Override |
|---|---|
| BG1 `$4000/$0000` 4bpp Konami logo bar | force wide and repeat row-1 col-15 over the bad/right-side bar cells |
| BG2 `$6000/$0000` Konami logo | keep 4:3 so the logo does not repeat in the strips |
| BG3 `$6400/$4000` 2bpp, first cell not `$1C00` and first row has nonzero cells | force wide for startup animation, main menu, and character select text |
| BG3 `$6400/$4000` 2bpp, first cell `$1C00` | keep 4:3 for the title/intro slate |
| BG3 `$6400/$2000` 2bpp | force wide for the save/select UI |
| BG1 `$6800/$5000` with BG3 row-0 menu marker at cols 13-16 | force wide for the main menu |
| BG1 `$6800/$5000` without the menu marker, or `$6800/$2000` | keep 4:3 for character select/loading screens |
| BG2 `$7000/$2000` | keep 4:3 for character select |

The patched bsnes-hd defaults are:

| Core option | Default |
|---|---|
| `bsnes_mode7_wsMode` | `all` |
| `bsnes_mode7_widescreen` | `16:9` (upstream default) |
| `bsnes_mode7_wsobj` | `unsafe` |
| `bsnes_mode7_wsbg1` | `off` |
| `bsnes_mode7_wsbg2` | `on` |
| `bsnes_mode7_wsbg3` | `off` |
| `bsnes_mode7_wsbg4` | `on` |
| `bsnes_cpu_overclock` | `130` (130%, stock `100`) |
| `bsnes_cpu_fastmath` | `ON` (stock `OFF`) |

The source note for layer settings repeated layer 4 in both the off/on lists; the
current bundled core uses the coherent 1/3 off, 2/4 on configuration. The CPU
overclock and Fast Math defaults are a performance tweak (BizHawk only feeds the core
its option defaults, so they cannot be set from a UI): the 130% overclock gives the
emulated SNES CPU headroom in sprite-heavy widescreen scenes, and Fast Math removes
the multiply/divide delays. Update the tracked DLL deliberately with
`tools/build_bsnes_hd_core.py` if that calibration changes.

### Gameplay HUD and radar (currently DISABLED)

Beyond the startup/menu guards above, the renderer also repositions the **in-level UI**
so it tracks the wider view instead of floating centered in the 4:3 middle. **All three
pieces below are presently commented out** in `tools/bsnes_hd_libretro_wram.patch`
(search `TEMP DISABLED`): the radar-dot sprite shift was also moving some priority-3
weapon sprites, so the whole anchor was disabled pending that fix. Re-enable the three
sites together.

- **HUD left-anchor** (`sfc/ppu-fast/background.cpp`): when the gameplay HUD layer is
  live, BG3 (`$6400/$4000`) is forced wide and its tilemap sampling is shifted left by
  the strip width, so the 256 px status bar anchors to the left screen edge. Detected
  with `$0E == 2` (in a level) **and the live map row-stride `$B2 != 0`** (map loaded).
  `$B2` is used instead of the player-active flag `$0D25` because `$0D25` briefly drops
  to 0 during transient animations such as the **pool dive**, which made the HUD snap
  back to centered for a few frames; `$B2` stays set throughout a loaded level and is 0
  only on the between-level/password/load screens.
- **Radar underlay** (`sfc/ppu-fast/line.cpp`): the radar inset's darkened backing is a
  color-math window (window 1, positioned per scanline by HDMA writing `$2126/$2127`).
  bsnes-hd centers it (`+ws`); on the radar's own scanlines during gameplay the `+ws`
  is dropped so the underlay left-anchors with the HUD.
- **Radar dot** (`sfc/ppu-fast/object.cpp`): the flickering neighbor dot is the
  top-priority (priority 3) sprite the game parks inside the radar box
  (screen ~`x[22,72] y[48,106]`, cycling one victim per ~2 frames); it is shifted left
  by the strip width to track the underlay. **This box-rect + priority-3 test is the
  weak point** — it also caught some weapon sprites, hence the disable; it needs a
  tighter discriminator before re-enabling.

---

## 4. How the ROM hook works

bsnes-hd renders the strips; our hook keeps the BG1 tilemap's strip columns fresh.
It maintains **`NSTRIP`=10 columns just outside the 256 px window on each side** (20
total) in VRAM, feeding the game's own VRAM-DMA queue so uploads land in vblank.

### Incremental gather (the key to staying cheap)

The camera moves ~**2 px/frame** (Mesen-measured), so a genuinely new tile column only
appears every ~4 frames. A VRAM column, once written, **persists at its ring slot as
the camera scrolls** (ring-buffer property), so re-filling all 20 columns every frame is
almost entirely wasted work — and at 20 columns it overran the CPU budget (the cause of
the severe slowdown). Instead, each frame the gather does only:
- **leading:** if the camera crossed a tile boundary this frame (`|Δcol|≥1`), gather the
  newly-exposed outermost column(s) on the leading side (capped at `LEADCAP`=3).
- **trickle:** a round-robin of `TRICKLE`=4 columns, so the rest (and especially the
  strips' top/bottom edges during **vertical** scroll, and columns after a direction
  reversal) refresh within about 5 frames.
- **full refill** only on the first gameplay frame or a ≥`FULLJMP`=4-tile jump
  (level load / warp) — a one-frame cost that's invisible behind the transition.
- **idle skip:** after camera tile movement stops, `REFDEBT` lets the trickle run long
  enough to refresh every strip column once, then the gather does no column work until
  the camera crosses another tile row/column.

Moving-camera work is therefore about `leading + TRICKLE` columns (typically 4-7),
**independent of `NSTRIP`**, and stationary-camera work drops to zero after the catch-up
debt expires. The heavy loop runs with **`DB=$7F`** (map/colbuf/scratch become cheap
absolute accesses) and walks the map with the live row stride `$B2`.

### Hooks

| Hook | Site | Context | Job |
|---|---|---|---|
| **GATHER** | `$80:A93F` (scroll dispatcher entry, via trampoline) | active display, **gated once/frame** | Re-run the original dispatcher, then gather the selected (leading + trickle) columns into colbufs and record each column's VRAM destination. No queue. |
| **ENQUEUE** | `$80:9E7B` (VRAM-queue drain entry, via trampoline) | vblank, cheap | Append the just-gathered colbufs to the game's VRAM-DMA queue, **mark each consumed (`$FFFF`)** so it isn't re-uploaded, set the dirty flag, then continue the original drain (which DMAs them and zeroes `$CE`). |
| **CAMERA** | `$80:A68B` / `$80:A70A` (horizontal scroll left/right) | scroll edge checks | Stop horizontal camera scroll with tuned left/right margins, while true off-map strip columns are filled black instead of leaving stale BG1 data. |

GATHER/ENQUEUE are split because the gather must stay out of vblank while VRAM uploads
must happen **in** vblank. The dispatcher is NMI-driven and called many times per
frame (1 px camera step each), so the gather is gated to run **once per frame** via
tick `$20`. CAMERA is separate and leaves the stock scroll code in charge until the
widescreen strip would cross a horizontal level edge.

### Routine + memory layout

Routine lives in free ROM at **`$8F:CC00`** (1760 free bytes before the reserved black
tile data; 1177 used, 583 free), plus a 14-byte same-bank sprite-cull helper in the
free pocket at `$80:FF68`. Scratch lives
in free high WRAM (the level map ends ~`$7F:8F00`, so `$7F:F000+` is free; the DX mailbox
at `$7F:FFF0` is already proven free):

```
$7F:F000-$F4FF   colbuf      20 columns × 64 bytes (32 tiles each), ring-ordered
$7F:F500-$F531   scratch     cam/ring/thresh, slot state, deltas, lead window,
                             PREVCOL PREVROW REFCUR INITDONE LASTTICK REFDEBT
$7F:F540-$F567   VRAMDEST    20 words ($FFFF = no pending upload / consumed by drain)
$7F:FFF0-$FFF9   (DX analog mailbox)
```

Reserved ROM data lives at `$8F:D2E0-$8F:D2FF`: a 32-byte opaque black 4bpp tile (solid
pixel color index `8`). During gameplay the off-map cell uses palette 0, and CGRAM `$08`
(palette 0, color index 8) is black on every level tested — color index 8 is the engine's
"black" (black in BG palettes 0,2,3,4,5 and every sprite palette). See §6 bug 9 for how
this was (mis)calibrated before.

### Per-column pipeline (for a gathered column)
For strip column offset `off` (`-10..-1` and `+32..+41`) and world-col
`mc = camera_col + off`:
1. **gather:** walk 32 rows from `$7F:( camrow*stride + mc*2 )` stepping by the live row
   stride `$B2`; apply priority `(cell & $1FF) < $DC → OR $2000`; store ring-ordered into
   `colbuf[ ($1B7A + row) & 31 ]`. If `mc` is outside the map, fill the column with the
   opaque black tilemap cell `$227F` (priority | palette 0 | tile `$27F`).
2. **dest:** `VRAMDEST = $1B7E + $80:9D77[(($1B76 + off) & 63)*2]`.
3. **enqueue (vblank):** queue entry `src=colbuf, bank=$7F, vram=VRAMDEST,
   vmain=$0081 (vertical +32), size=$0040`; then `VRAMDEST := $FFFF` (consumed).

The off-map black fill is **gameplay-only** (`$0E == 2 && $0D25 != 0`). The gather writes
the `$227F` cells (step 1), and the enqueue uploads the black tile graphics to VRAM
`$77F0` on full-refill frames (level start / warp); tile `$27F` is an unused BG1 slot the
game never DMAs over, so it persists between refills. Nothing black-related runs during
loading/menu states, so the loading-screen text is never touched.

### Camera edge clamp

Stock ZAMN locks the horizontal camera at `0` on the left and `$00B8` (max camera X)
on the right. With 10 widescreen strip columns visible on each side, bsnes-hd can see
80 px beyond those stock edges, so the widened view would expose stale/off-map BG1
tilemap columns even though the normal 4:3 window still looks fine.

The widescreen patch hooks the stock left/right scroll checks and returns early when
the camera reaches tuned margins inside the level bounds. These margins are smaller
than the 10-column BG fill width so the clamp does not hide real level data:

- left edge: `cameraX >= 8*8` (currently `$0040`)
- right edge: `cameraX <= $00B8 - 8*8`

On level 1, Mesen reports `$00B8=$0480`, so the right widescreen clamp is `$0440`.
Vertical camera bounds are unchanged. If a level starts with the camera already past
one of these margins (level 2 starts at the very left edge), any truly off-map strip
columns are painted with opaque black BG1 cell `$227F` rather than repeating edge data
or leaving stale VRAM.

### Sprites (OAM X-cull relax)

The OAM-build engine (`$80:BA6F-$BDC9`) only writes a sprite to the OAM shadow if its
screen-X is in `[-15, 255]`; anything further into a strip is culled. Four identical
cull sites (`$80:BA74/$BAE4/$BB5A/$BBD7`) each do `CMP #$0100 / BCC draw / CMP #$FFF1 /
BCC cull / <set X-high bit>`. The optimized patch keeps the stock on-screen fast path
exactly shaped as `CMP #$0100 / BCC draw`, then uses a same-bank `JSR $FF68` helper only
for X values outside the 4:3 screen. That helper widens the visible range to
`[-SPRITE_MARGIN, 255+SPRITE_MARGIN]` (=±80 px, matching the BG strips) and returns
carry set for true culls. The site keeps its **own** original set-high bytes (sites
1-3 `ORA`, site 4 `EOR`) so a strip sprite gets its X-high bit and bsnes-hd renders it
in the strip. This avoids the old `JSL` cost on every ordinary on-screen sprite tile.

**Display-only and no aggro change:** this only changes which *already-active* actors
get an OAM entry — an enemy off the right edge already has its AI running; we just let
it be *drawn* in the strip. Mesen-verified: stock culls both strip X-ranges to 0; the
patch draws them (`right=3, left=5` in a sample), with identical actor positions.

That OAM-X-cull fixed **enemies/player/projectiles**. **Items & survivors are a separate,
deeper case** (the cull above does not affect them) — investigation below.

### Sprites part 2: items, neighbors, and spawners

**Update from the user savestate (2026-06-18):** the "type `$05` items/survivors"
theory was too narrow. In the saved left-walk scene, the edge objects are map-object
types such as `$0C`, `$01`, `$00`, and `$21`; type `$05` is centered on the player.
The relevant problem is upstream activation, not the final OAM cull: inactive
map-object/victim definitions already hold the correct sprite/type/X/Y data, but
stock ZAMN does not activate them until the scanner sees them near the 4:3 window.

Implemented fix:
- `$80:C948` map-object X proximity gate widened from `CMP #$0090` to
  `CMP #$00E0` (`$0090 + SPRITE_MARGIN`). This changes the horizontal activation
  and deactivation range from about `[-15,271]` to about `[-95,351]`, covering the
  80 px widescreen strips while leaving the vertical gate unchanged.
- `$80:C91C` scanner cadence stays stock: `($20 & 3) == 0`. Earlier builds ran this
  more often to reduce edge pop-in, but stock cadence is cheaper and works once the
  display-side culls are tightened.
- `$81:823C` victim/neighbor definition scanner X gate widened from `CMP #$00A0`
  to `CMP #$00F0` (`$00A0 + SPRITE_MARGIN`). Stock wakes left-side victims at about
  `screenX=-31`; the widened gate covers about `screenX=-111` while leaving the
  vertical gate unchanged.
- User savestate verification showed type `$0C` item/map-object OAM and type `$01`
  neighbor OAM can render in the left strip once the stock-cadence scanner reaches
  them; the final OAM software cull still decides per-tile visibility.

The older type-`$05` render-list relax remains in the current build as a synthetic
display-only bypass for active unlisted slots, but the real saved-scene fixes are the
map-object and victim activation gates above.

#### Earlier type-`$05` investigation (kept for reference)

Reported after the OAM-X-cull shipped: enemies appear in the strips but **items and
survivors still pop in at the 256 px edge**. Traced empirically (Mesen write/exec
callbacks; tools below). Findings:

- **One OAM engine.** A write-callback on the whole OAM shadow (`$7E:13BE-$15DD`) shows
  *every* sprite byte is written by the bank-`$80` engine `$BA5E-$BDCC` — there is no
  second renderer. Entry is `$80:BD1F` (per-frame, called from the main loop), reached
  by fall-through, not `JSR`/`JSL`.
- **The pipeline:** objects live in a `$1B5E` linked list → builder `$80:BCEA` walks it,
  culls each into the render array `$137E`, then engine `$BD1F` iterates `$137E`.
  Stock uses `screenX/Y ∈ [-128, 384)` here; the widescreen shim keeps the stock
  horizontal render-list range `[-128, 384)` (it already covers the 80 px strips plus
  ~48 px of sprite overhang) while leaving the stock vertical range unchanged. An
  earlier optimization narrowed this to `[-96, 352)` (strip + one 16 px tile) and
  clipped wide neighbors/enemies/items at the strip edge — their anchor fell outside
  the gate while their leading tiles were still visible — so the gate was restored to
  the stock margin (`RENDER_X_MARGIN = SPRITE_MARGIN + 48`). Per-object setup
  `$80:BD79` then computes `screenX = objX - $1B6A`,
  and the draw loops (the 4 patched per-tile culls) emit or cull final OAM.
- **The actual gate (empirical).** Hooking the setup `$BD79` and the builder `$BCEA` and
  bucketing by object type (`$0E,X`): types `$00/$01/$03` (player/enemies/projectiles)
  reach both in the strips; **type `$05` reaches them only on-screen (0 in either strip,
  ~1000+ on-screen).** So type `$05` is dropped from the `$1B5E` list *before* the builder
  — i.e. gated by proximity to the ~256 px window, upstream of every cull we can see.
- It does **not** use the normal render-list insert/remove (`$80:BE28`/`$80:BE51`); a
  trace of those caught only types `$00/$01/$03`.
- **Earlier implemented relax:** the widescreen build now replaces the stock
  `JSR $BCE2 / JSR $BC23` pair at `$80:BD2A` with `ws_build_render_list`. It rebuilds
  `$137E` like stock, scans the 32 object slots `$185E-$1ACA`, and appends active
  type-`$05` slots that are inside the widened horizontal range but missing from
  `$137E`. It then performs the stock OAM-shadow clear. This leaves `$1B5E` and
  object state untouched; only the current frame's flattened render array can grow.
- **Do NOT touch** the bank-`$81` type-3/4 routine + `$80:B22A`/`$80:B093`: those compute
  `|delta|` vs 256 *and* 17 px and call overlap tests (`$80:ADC8`) — that's collision /
  pickup / interaction (gameplay), not rendering.
- **Disassembler caveat:** `re65816.py` doesn't track the `REP`/`SEP` M/X widths, so dense
  engine code mis-aligns; `$80:9D77` is the **VRAM-column data table** (used by the BG
  hook), *not* a dispatcher — a mis-decode sent me down one dead end. Verify engine
  branch targets against the raw bytes.

**Mesen verification:** the deterministic up/left route does not naturally put a type-`$05`
object into a horizontal strip, so it cannot prove the user's exact bsnes-hd scene. A
synthetic check (`mesen_type05_inject_verify.lua`) clones an already-active type-`$05`
slot into the left strip without linking it through `$1B5E`; the patched renderer appends
it to `$137E` and emits strip OAM (`saw_render=true`, `peak_left_strip_oam=5`). This
proves the display-only bypass works when an active type-`$05` slot exists in a strip.
Real bsnes-hd visual confirmation is still required.

---

## 5. Reverse-engineered facts (Mesen-verified live where noted)

| Thing | Value |
|---|---|
| Level map | `$7F:0000-$8EFF`, contiguous; `cell(col,row) = $7F:( rowbase + col*2 )` |
| Row-base table | `$7E:4328[row*2]` → row's start in `$7F` |
| Map width / rowstride `$B2` | `$0160` = 176 tiles wide (live) |
| BG1 tilemap base `$1B7E` | `$7800` (live), 64×32 (two 32-col quadrants) |
| BG1 ring origin | `$1B76` = tilemap col at camera left; `$1B7A` = tilemap row at camera top |
| VRAM column table | `$80:9D77[ colidx*2 ]`, `colidx = ($1B76 + strip_offset) & 63` |
| Priority threshold `$DC` | `$70` (live); `(cell & $1FF) < $DC → set $2000` |
| VRAM-DMA queue | `src $1B84 / bank $1BB4 / vram $1BE4 / vmain $1C14 / size $1C44`, len `$CE`, dirty flag `$26` |
| Queue drain | `$80:9E7B` (`BIT $26; BVS $9ECE; LDA $CE; BEQ $9ECB; …`), zeroes `$CE` at `$9EBF` |
| Scroll dispatcher | `$80:A93F` (`PHD; LDA #$0000; TCD …`), reached via pointer at `$80:A93C`; moves camera 1 px/call |
| Horizontal camera scroll | left check `$80:A68B`, right check `$80:A70A`; stock clamps at `0` / `$00B8`, widescreen clamps at `$0040` / `$00B8-$0040` |
| Task scheduler | cooperative; tasks `$1180,X`, saved SPs `$11B0,X`; main loop `$8340-$8398`; `WAI` at `$8371`; **per-frame tick `$20/$22`** incremented at `$8372`; `JSL $80BD1F` at `$837C` |
| Camera (pixels) | `$1B6A` / `$1B6C` |
| Camera max X | `$00B8` (`$0480` on level 1) |
| Guards | `$0E` game-state (`2` = in a level); `$0D25` player-active (`0` during level load) |
| Off-map black (gameplay only) | BG1 cell `$227F` = priority + palette 0 + tile `$27F`; solid color-index-8 tile graphics uploaded to VRAM `$77F0` (gameplay char base `$5000` + `$27F*16`); CGRAM `$08` is black on every level tested |

---

## 6. Debugging journey (bugs found & fixed)

The first builds crashed/hung. Diagnosed entirely with **Mesen headless tracing**:

1. **Ran during level load.** Guard was only `$0E == 2`, which includes the load
   phase. → Added `$0D25 != 0` (player-active) guard.
2. **Pinned the VRAM queue → deadlock.** Hooking the dispatcher and appending to the
   queue left `$CE != 0`; the game's *"wait for queue empty"* spin-waits (`$80:8372`
   scheduler, `$80:A545` load) never completed. → Moved the **enqueue into the drain
   hook** so the drain DMAs our entries and zeroes `$CE`.
3. **Starved the main loop.** The dispatcher is NMI-driven and called many times per
   frame, so the heavy gather ran repeatedly in vblank and the game's tasks never got
   CPU (camera frozen). → **Gated the gather to once per frame** via tick `$20`.
   (An attempt to gather at an active-display point `$80:837C`/`$BD1F` crashed at
   **boot** because wrapping it shifts the cooperative scheduler's task stack pointers
   — reverted.)
4. **Clobbered the dispatcher's return.** The gather trampoline didn't preserve
   `A/X/Y`, which the dispatcher's caller uses. → Preserve `A/X/Y` across the gather.
5. **Wrong tilemap coordinate space.** The first visual bsnes-hd test showed the
   filled strips appearing inside the 4:3 viewport. The hook used `world_col & 63`
   and `world_row & 31`, but the game uses a BG1 ring buffer: `$1B76/$1B7A` are the
   tilemap col/row for the camera's top-left tile. → Destination columns and colbuf
   rows now use `$1B76 + strip_offset` and `$1B7A + row_offset`, while map reads still
   use the true world column/row.
6. **Severe slowdown + a thin unfilled strip.** The first correct build refilled *all*
   strip columns *every* frame. Widening to cover the screen (≈10 cols/side) pushed the
   per-frame gather past the CPU budget → severe slowdown; a thin outer strip was still
   unfilled. → Made the gather **incremental** (leading column + round-robin trickle;
   full refill only on load/warp) so per-frame cost is bounded and independent of strip
   width, and sped the inner loop (`DB=$7F` absolute, running `+$160` row pointer). The
   enqueue now **consumes** each column (`VRAMDEST:=$FFFF`) so only freshly-gathered
   columns re-upload. (See §4.) Camera speed was Mesen-measured at ~2 px/frame, which
   sets the leading/trickle cadence.
7. **Level 2 completely broken (per-level row stride).** The fast inner loop from bug 6
   stepped the map pointer by a hardcoded `+$160` — that's only level 1's row stride
   (map width). Map width is **per level** (`$B2`), so on a different-width level the
   step read the wrong rows → garbage strips. → Step by the **live `$B2`** instead
   (`SRCEND = start + 32*$B2`); the row start still comes from the game's `$7E:4328`
   table (handles any base), so the walk matches the game's own streaming for any level.
   Also added a stride-change check (`$B2` differs from last frame ⇒ full refill) so a
   level transition repaints cleanly. *Lesson: `mesen_ws_verify.lua` only runs on level
   1, where `$B2`=`$160`, so it can't catch a hardcoded-stride bug — verify on level 2+.*
8. **Horizontal level edges exposed off-map/stale BG1 data.** The first clamp used one
   full strip width (`$0050`) on both sides, which hid a little too much real level data.
   It also could not help when a level started with the camera already past the clamp
   (level 2 does this), because no left/right scroll check had run yet. The final margin
   is 8 tiles on both sides (`$0040` left, `$0040` right), so level 1 clamps at
   `$0040..$0440` when `$00B8=$0480`. True off-map strip columns are filled with the
   opaque black cell `$227F` during gameplay (level 2 starts already at the left edge,
   so its left strips are off-map from frame 1).
9. **Transparent black was not enough.** Plain cell `$0000` lets lower-priority BG2
   data show through, so off-map garbage stayed visible. Black therefore needs an
   *opaque* tile: a solid tile referenced with the priority bit so BG1 wins over BG2.
   (Choosing the right tile + palette is bug 11 — the first attempt got both wrong.)
10. **Idle gather cost.** Even after the incremental rewrite, the hook kept trickling
   columns forever while the camera was tile-stationary. `REFDEBT` now keeps trickle
   alive only long enough to refresh every strip column once after movement, then skips
   column work until the camera crosses another tile row/column.
11. **Off-map "black" was green, and the load-frame fill broke the loading text.** The
   first opaque-black attempt was calibrated from the user's level-2 **loading-text**
   savestate: it assumed BG1 char base `$1000` (tile `$3FF` → VRAM `$4FF0`) and palette 2
   color `$A` (`CGRAM $2A`). Both are wrong for **gameplay**: gameplay `$210B=$25` so BG1
   char base is `$5000` (verified via BG2/BG3 cross-check that Mesen's `chrAddress` is in
   *words*), and once the level palette loads `CGRAM $2A` is `62EB` (teal), not black —
   so the off-map tile rendered transparent (tile `$3FF` is the engine's blank cell) and
   the green backdrop (`CGRAM $00 = 29C1`) showed through. Worse, to make the load frame
   black the enqueue uploaded that tile + queued black columns **during non-gameplay
   states** (`$0E != 2`), which is exactly the loading-text screen → it clobbered the
   font at `$4FF0` and the text tilemap. Fix: (a) **gameplay-calibrated** black — solid
   color-index-8 tile (`CGRAM $08` is black on every level: index 8 is black in BG
   palettes 0,2,3,4,5 and all sprite palettes) hosted at a verified-free, never-referenced
   BG1 slot (`$27F` → VRAM `$77F0`), cell `$227F`; (b) **gameplay-only gating** — all
   black-fill now lives behind the `$0E==2 && $0D25!=0` guard, so loading/menu VRAM is
   never touched. `mesen_black_fix_verify.lua` confirms off-map cells are `$227F`, the
   tile at `$77F0` is solid color-8, `CGRAM $08==0`, and **zero** bank-`$8F` (black-fill)
   DMAs occur across 127 non-gameplay drains. *Lesson: calibrate display constants
   (palette/char-base/VRAM) from the **gameplay** state, never a load/menu savestate.*
12. **Many-sprite slowdown from widened OAM culls.** The first sprite-strip patch sent
   every sprite tile through a long `JSL` helper, including ordinary on-screen sprites.
   Final fix: keep the stock `CMP #$0100 / BCC draw` fast path at all four cull sites,
   and call a 14-byte same-bank helper at `$80:FF68` only for offscreen/strip candidates.
   The per-tile OAM cull (`SPRITE_MARGIN`=80) bounds what is actually drawn. The
   active-actor render-list X range is kept at the stock `[-128, 384)` margin
   (`RENDER_X_MARGIN = SPRITE_MARGIN + 48`): it already covers the 80 px strips with
   ~48 px of sprite overhang, so wide actors are not dropped from `$137E` while their
   leading tiles are still on the strip edge. (A brief `[-96, 352)` narrowing clipped
   those actors and was reverted — the render-list walk is cheap, so there is no point
   trimming it below the OAM cull's needs.) The map-object scanner cadence is back to
   stock (`$20 & 3`).

Result: the BG hook is data-correct across all 20 columns (`mesen_ws_verify.lua`
`failures=0`), `$CE` returns to zero, horizontal camera edges stay inside the real
level map, and true off-map columns are opaque black during gameplay while loading/menu
screens are left untouched.

---

## 7. Tooling built (reusable)

| Tool | Purpose |
|---|---|
| `tools/asm65816.py` | Minimal two-pass 65816 **assembler** (labels, all addressing modes). Validated by round-trip through the disassembler. |
| `tools/diagnostics/re65816.py` | 65816 **disassembler** + PPU/DMA register-write **scanner**. `dis bb:aaaa N`, `scan`, `--rom`. |
| `tools/build_widescreen.py` | Assembles the hook, applies both trampolines + the routine to the DX ROM, fixes checksum, emits `mod/widescreen.ips` and a ready test ROM. |
| `tools/build_bsnes_hd_core.py` | Patches a bsnes-hd libretro DLL's core-option defaults to produce the repo-owned ZAMN-DX core DLL. The source DLL must already include `tools/bsnes_hd_libretro_wram.patch`; release builds do not download or regenerate this automatically. |
| `tools/build_bsnes_hd.ps1` | One-step core rebuild (Windows + MinGW-w64): ensures `bsnes_hd_libretro_wram.patch` is applied to the source tree, compiles the libretro target (`mingw32-make -C bsnes target=libretro`), bakes the option defaults via `build_bsnes_hd_core.py`, and deploys the DLL into any staged `dist/release/*` test runtime. |
| `tools/diagnostics/mesen_wram_probe.lua` | Dumps live WRAM (found map extent + free scratch). |
| `tools/diagnostics/mesen_ws_trace.lua` | Stability/scroll trace (catches hangs, logs camera). |
| `tools/diagnostics/mesen_ws_verify.lua` | BG data-correctness check (colbuf ↔ map ↔ VRAM). |
| `tools/diagnostics/mesen_camera_bounds_probe.lua` | Natural-route camera trace; confirms left clamp reaches `$0040` instead of stock `$0000`. |
| `tools/diagnostics/mesen_camera_clamp_verify.lua` | Controlled right-edge proof; forces camera attempts at `$043F/$0440` and confirms `$0440` blocks when `$00B8=$0480`. |
| `tools/diagnostics/mesen_offmap_black_verify.lua` | Verifies true off-map strip columns upload opaque black `$227F` to colbuf and VRAM on both horizontal clamped edges (level 1). |
| `tools/diagnostics/mesen_gameplay_black_probe.lua` | **Gameplay** black calibration: plays the level-2 savestate (or boots to level 1, `MODE`) forward into settled gameplay and dumps CGRAM, BG char bases, and free/unused BG1 tile slots. Found char base `$5000`, `CGRAM $08` black, free tile `$27F`. |
| `tools/diagnostics/mesen_black_fix_verify.lua` | End-to-end fix check: off-map cells `$227F` + solid color-8 tile at `$77F0` + `CGRAM $08==0` during gameplay, **and** zero bank-`$8F` black-fill DMAs across all non-gameplay (loading) drains. |
| `tools/diagnostics/mesen_startup_ui_probe.lua` | Loads Mesen startup/menu save slots 1-7 and dumps the BG layer bases plus involved VRAM tilemap rows, used to key the bsnes-hd startup renderer guards. |
| `tools/diagnostics/_scan_bgnba.py` | ROM scan for `$2105/$210B/$210D/$2107` writes (found gameplay `$210B=$25` → BG1 char base `$5000`). |
| `tools/diagnostics/mesen_level2_load_probe.lua` | *(superseded)* Loaded the user level-2 savestate to verify the old load-state black fill — that path was removed (it clobbered the loading text). |
| `tools/diagnostics/mesen_blank_tile_scan.lua` | *(superseded — sampled the load screen)* Palette/tile scan that first (mis)concluded palette 2 color `$A` was black; see §6 bug 11. |
| `tools/diagnostics/mesen_sprite_probe.lua` | Counts sprites in the strip X-ranges (stock 0 vs patched >0). |
| `tools/diagnostics/mesen_oam_writers.lua` | Write-callback on the OAM shadow → every OAM-writer PC (found the one engine). |
| `tools/diagnostics/mesen_cull_trace.lua` | Exec-callback at an engine point → per-object-type screen-region histogram (found type `$05` never in strips). |
| `tools/diagnostics/mesen_reglist_trace.lua` | Exec-callback at render-list insert/remove → callers + screenX thresholds. |
| `tools/diagnostics/mesen_type05_probe.lua` | Counts active/rendered type-`$05` objects by screen region on the up/left route. |
| `tools/diagnostics/mesen_type05_write_trace.lua` | Write-callback for type-`$05` slot initialization; found the load-time pair around `$80:D1A0/$80:D1B9`. |
| `tools/diagnostics/mesen_type05_lifecycle.lua` | Per-frame type-`$05` slot/list/render membership log for route debugging. |
| `tools/diagnostics/mesen_type05_inject_verify.lua` | Synthetic proof that an active unlisted type-`$05` strip slot is appended to `$137E` and drawn. |
| `tools/diagnostics/mesen_route_trace.lua` | Logs camera/player movement for deterministic route debugging. |
| `tools/diagnostics/mesen_savestate_object_sweep.lua` | Loads the user savestate and dumps active/rendered object slots while walking left. |
| `tools/diagnostics/mesen_savestate_sprite_cull_trace.lua` | Buckets patched OAM-cull calls by object type for the user savestate. |
| `tools/diagnostics/mesen_savestate_final_oam.lua` | Confirms strip sprites survive into final 9-bit SNES OAM entries. |
| `tools/diagnostics/mesen_savestate_spawn_trace.lua` | Traces object-slot activation writes in the user savestate. |
| `tools/diagnostics/mesen_savestate_target_slot_trace.lua` | Focused write trace for the specific late-spawning slots in the user savestate. |
| `tools/diagnostics/mesen_savestate_a13e_callers.lua` | Identifies which bank-`$83` initializer callers create the saved-scene child objects. |
| `tools/diagnostics/mesen_savestate_victim_trace.lua` | Dumps victim-task scheduler/DP state for the left-strip neighbor save. |
| `tools/diagnostics/mesen_savestate_victim_gate_verify.lua` | Diagnostic-only RAM reset proving the widened victim scanner wakes the saved-scene cheerleader in the strip. |
| `tools/diagnostics/mesen_radar_probe.lua` | Dumps full PPU state + OAM for a save slot (`ZAMNDX_SLOT`); identified the radar inset as a color-math window (underlay) plus a cycling priority-3 sprite (dot). |
| `tools/diagnostics/mesen_radar_shot.lua` | Saves a 4:3 PNG screenshot of a save slot — visual grounding for the radar/HUD work. |
| `tools/diagnostics/mesen_pool_hud_probe.lua` | Per-frame HUD-guard trace across the pool-dive transition; showed `$0D25` dropping to 0 for ~5 frames while the map stride `$B2` stays set. |
| `tools/diagnostics/mesen_hud_survey.lua` | One-shot HUD-state survey of a slot (`$0E`/`$0D25`/`$B2`/BG bases/BG3 rows) to tell the pool dive apart from a level-load. |

**MesenCE Lua API (for the above):** memory/exec callbacks via
`emu.addMemoryCallback(fn, emu.callbackType.{read,write,exec}, start, end, emu.cpuType.snes, emu.memType.X)`
— for the OAM shadow use `memType=snesWorkRam` with WRAM offsets; for exec use
`memType=snesMemory` with the 24-bit code address (e.g. `0x80BD79`). Read registers in a
callback with `emu.getCpuState(emu.cpuType.snes)` (`.k/.pc/.x/.y/.d/.sp/.dbr`); `emu.getState()`
is a flat table with dotted keys (`"cpu.pc"`), so `.cpu` is nil — use `getCpuState`.

**Mesen headless** (the key debugging unlock) — this build is **MesenCE**, a GUI-
subsystem app. Two gotchas that look like an instant no-op if you get them wrong:
the testrunner takes **ROM first, then script**, and the shell must **wait** for it
(`Start-Process`/`&` return immediately for a GUI app). Run it via `cmd` with stdout
redirected so the shell blocks until `emu.stop()`:
```
cmd /c '"...\Mesen_2.2.1\Mesen.exe" --testrunner "<rom.sfc>" "<script.lua>" > log.txt 2>&1'
```
The process exit code is the script's `emu.stop()` arg (here 0 = pass, 1 = failures,
2 = never reached gameplay). Scripts navigate menus to gameplay, read/trace memory,
write a report, then `emu.stop()`.

---

## 8. Build & test

```powershell
python tools/build_widescreen.py
```
Produces:
- `dist/Zombies Ate My Neighbors DX Widescreen.sfc` (DX + widescreen, checksum fixed)
- `mod/widescreen.ips` (stacks on the DX ROM)

The launcher applies `mod/widescreen.ips` as a default-on optional patch and
launches the patched ROM in BizHawk through the bundled bsnes-hd libretro core.
For standalone visual checks, use bsnes-hd with `WideScreen Mode = all scenes`
and render sprites anywhere.

To rebuild the **bundled bsnes-hd core** after editing
`tools/bsnes_hd_libretro_wram.patch` or the source tree (`.tools/bsnes-hd-src`), run the
one-step script (needs a MinGW-w64 toolchain — `mingw32-make` + `g++`):

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_bsnes_hd.ps1
```

It compiles the libretro target, bakes the ZAMN-DX option defaults, writes
`mod/bsnes_hd_beta_zamndx_libretro.dll`, and deploys it into any staged test runtime.

---

## 9. Remaining work

- [x] **Data-correctness check** — `mesen_ws_verify.lua` passes for all 20 columns
      (`failures=0`): after scrolling then holding still, colbuf and VRAM match the map.
- [x] **Strip width** — `NSTRIP`=10 columns/side (≈80 px). Cost no longer scales with
      width (incremental gather), so bump freely for ultrawide.
- [x] **Slowdown** — fixed via incremental gather, faster inner loop, lower trickle
      budget, black-tile upload gating, and idle gather skip (§4, §6 bugs 6/10).
- [x] **BG confirmed in bsnes-hd** (user, 2026-06-18) — strips fill to the edge, smooth.
- [x] **Sprites (enemies/player/projectiles)** — OAM X-cull relaxed to ±80 px
      (§4 *Sprites*); Mesen-confirmed the strip X-ranges go from 0 (stock) to non-zero
      (patched). Display-only. User-confirmed in bsnes-hd.
- [x] **Sprites (items & neighbors / spawners)** - widened the `$80:C948`
      map-object X activation/deactivation gate to `$00E0`, kept that scanner at the
      stock every-4-wakes cadence, and widened the `$81:823C` victim scanner X gate to `$00F0`.
      The final OAM software cull remains active with a widened horizontal range.
- [x] **bsnes-hd visual confirmation for items/neighbors** - user-confirmed both item
      and neighbor strip rendering in standalone bsnes-hd.
- [x] **Horizontal level-edge clamp** - stock camera bounds now clamp earlier with
      tuned margins (`$0040` left, `$00B8-$0040` right), and true
      off-map strip columns upload opaque black `$227F` instead of stale VRAM.
- [x] **Off-map black (gameplay), loading text intact** - off-map strip cells are `$227F`
      (priority|pal0|tile `$27F`) backed by a solid color-8 tile at VRAM `$77F0`; calibrated
      to the real gameplay state (char base `$5000`, `CGRAM $08` black). All black-fill is
      gameplay-only, so the loading-text screen is no longer clobbered. `mesen_black_fix_verify.lua`
      passes (off-map black + 0 black-fill DMAs during loading). *(Replaces the earlier
      load-screen calibration that rendered green and broke the level-2 loading text — §6 bug 11.)*
- [ ] **bsnes-hd visual confirmation for level edges + loading text** - approach the left/right level
      edges and confirm the camera clamp looks clean in standalone bsnes-hd.
- [ ] **Tuning** — `SPRITE_MARGIN`/`NSTRIP`/`TRICKLE` if needed; alignment.
- [ ] **BG2** — the 32×32 second layer may need its own pass if it shows strip garbage.
- [ ] **Gameplay HUD / radar anchoring (DISABLED)** — the BG3 HUD left-anchor and the
      radar underlay/dot shifts are committed but **commented out** (`TEMP DISABLED`, §3):
      the radar dot's priority-3 box-rect shift also moved some weapon sprites. Narrow the
      sprite discriminator (e.g. require the dot's tile/palette signature or its single OAM
      slot) and re-enable the three sites together. The pool-dive guard fix (`$B2` map-loaded
      instead of `$0D25` player-active) is part of the same disabled block.
- [x] **Hosting** - launcher starts BizHawk through OpenAdvanced libretro when the
      Widescreen patch is enabled, using the repo-owned patched bsnes-hd DLL.
- [x] **Launcher integration** - Widescreen is a default-on optional ROM patch and
      is staged into releases with the matching bsnes-hd core.
