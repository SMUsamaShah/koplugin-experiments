# E-Ink Animation Lab

KOReader page-turn animation plugin for Kindle Paperwhite 4 / Rex. Version 0.4.1 uses the same repaint lifecycle architecture as the working KPW4 page-animation patch, while keeping the Motion Lab waveform, dithering and scheduling experiments.

## How page turns work

**Animate normal page turns** is enabled by default.

Animation Lab no longer takes over page navigation. KOReader handles taps, swipes, keys, RTL/inverse reading order and document navigation normally.

For an ordinary one-page turn the plugin now does this:

1. `Screen:beforePaint()` snapshots the old framebuffer.
2. KOReader renders the destination page normally into `Screen.bb`.
3. At the first physical refresh, Animation Lab copies that completed destination framebuffer.
4. The configured curl animation runs from the old framebuffer to the already-rendered new framebuffer.
5. KOReader's remaining queued physical refreshes for that paint cycle are suppressed because the animation has already displayed the destination.
6. One final `refreshUI()` settles the exact destination page into crisp grayscale.
7. The KOReader partial-refresh counter is rolled back, matching the proven KPW4 patch behavior so the animation does not shift the periodic full-refresh cadence.

The plugin only wraps `onGotoViewRel` to record the direction of eligible `+1/-1` page turns; it immediately calls KOReader's original handler. It does not replace the navigation operation itself.

Internal `no_page_turn` calls and multi-page jumps are left alone.

### Refresh interception detail

KOReader's `UIManager` caches references to the public `Screen.refresh*` functions when `uimanager.lua` loads. That means a plugin loaded later cannot reliably intercept repaint by replacing `Screen.refreshUI`, `Screen.refreshFast`, and similar methods. Version 0.4.1 fixes this by wrapping the dynamically-dispatched `refresh*Imp` implementation methods instead. The cached public refresh functions still call those implementation methods at the exact point before the panel update, so the animation can replace the queued page refresh without patching KOReader's `_repaint()` source.

## Menu

The menu contains only:

1. **Animate normal page turns**
2. **Page-turn animation settings**
3. **Test animated next page**
4. **Test animated previous page**
5. **update plugin**

The old synthetic diagnostics, duplicate refresh/frame controls and legacy preview implementation have been removed from the runtime path.

## Page-turn animation settings

The renderer uses a bowed moving page edge, shaded fold, highlight and cast shadow while refreshing only the region around the moving fold.

### Waveform

- **DU / Fast**
- **A2**

### Dithering

- **Grayscale / no dither**
- **SW Bayer**
- **SW stochastic**
- **SW Floyd-Steinberg**
- **SW Atkinson**
- **Plain B/W threshold**
- **Rex HW ordered**
- **Rex HW Floyd-Steinberg**
- **Rex HW Atkinson**

The Rex HW modes use the direct `MXCFB_SEND_UPDATE_REX` path explored by E-Ink Motion Lab and require a compatible Kindle Rex device.

### Scheduling

- **Free-running** — submit frames as soon as they are ready.
- **Fixed clock / skip late frames** — use absolute deadlines and skip obsolete logical frames when late.
- **Bounded EPDC queue** — cap outstanding update markers at the selected queue depth.
- **Synchronized** — wait for each frame to finish before submitting the next.

There are separate controls for target FPS, queue depth, frame count and free/bounded frame delay.

The default starting point is:

- DU
- Grayscale / no dither
- Bounded EPDC queue
- Queue depth 4
- 12 frames
- 4 ms delay

## Gesture / Quick Menu actions

The plugin also registers:

- **Animated page turn: next page**
- **Animated page turn: previous page**

These simply request an ordinary KOReader page turn; the same automatic repaint hook performs the animation.

## Self-update

**update plugin** is the final menu entry and uses the same reusable `pluginupdater.lua` as E-Ink Motion Lab.

It updates only `animationlab.koplugin` from the `main` branch of `SMUsamaShah/koplugin-experiments`, verifies the Git revision and downloaded blobs, checks Lua syntax, stages the replacement, keeps a backup for rollback, and offers to restart KOReader.
