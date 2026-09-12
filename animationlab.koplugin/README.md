# E-Ink Animation Lab

Experimental KOReader page-turn animation plugin for Kindle Paperwhite 4 / Rex. Version 0.3.2 applies the useful findings from E-Ink Motion / Grayscale Lab directly to normal reading.

## Normal page turns are animated automatically

**Animate normal page turns** is enabled by default.

When enabled, ordinary single-page navigation through KOReader uses the configured page-curl animation:

- tap forward/backward page zones;
- horizontal page-turn swipes;
- page-turn keys / `GotoViewRel ±1`;
- other normal single-step page turns routed through KOReader's page navigation.

Internal calls that explicitly request no page turn, multi-page jumps, and unsupported animation configurations fall back to KOReader's original navigation handler.

You can disable this behavior at any time with **Animate normal page turns**.

## Clean menu

The Animation Lab menu now contains only:

1. **Animate normal page turns**
2. **Page-turn animation settings**
3. **Test animated next page**
4. **Test animated previous page**
5. **update plugin**

The old Synthetic diagnostics, Refresh mode, legacy Frames / Frame delay controls, and Legacy previews are no longer exposed in the menu. Their old implementation remains internal for now because the real-page capture path still reuses parts of the original experiment.

## Page-turn animation settings

The renderer uses a bowed moving page edge, a shaded paper fold, a highlight and a cast shadow. Only the moving region is refreshed. Software dithering is applied to the fold/shadow region so normal book text outside it remains untouched.

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

The three Rex HW modes use the same direct `MXCFB_SEND_UPDATE_REX` path explored by Motion Lab and require a compatible Kindle Rex device.

### Scheduling

- **Free-running** — submit frames as soon as they are rendered, with the selected small frame delay.
- **Fixed clock / skip late frames** — use absolute frame deadlines and skip obsolete logical frames if rendering/submission falls behind.
- **Bounded EPDC queue** — cap outstanding update markers at the selected queue depth.
- **Synchronized** — wait for each frame to complete before submitting the next.

There are separate controls for target FPS, queue depth, animation frame count and the free/bounded frame delay.

A reasonable first PW4 comparison is:

- DU
- SW Bayer
- Bounded EPDC queue
- Queue depth 4
- 12 frames
- 4 ms frame delay

Then compare the same turn with A2, Free-running and Fixed clock.

## Gesture / Quick Menu actions

Animation Lab still registers:

- **Animated page turn: next page**
- **Animated page turn: previous page**

These remain useful for explicit gesture or Quick Menu assignments, but they are no longer required for ordinary page turns when automatic animation is enabled.

## Self-update

**update plugin** is the final Animation Lab menu entry and uses the same reusable `pluginupdater.lua` as E-Ink Motion Lab.

It downloads only `animationlab.koplugin` from the `main` branch of `SMUsamaShah/koplugin-experiments`, pins the update to one Git revision, verifies HTTPS and Git blob hashes, checks Lua syntax, stages the complete replacement, keeps the previous plugin folder as `.update-backup`, restores it if the final swap fails, and then offers to restart KOReader.

The updater file itself is deliberately reusable in other plugins: copy `pluginupdater.lua`, configure `repository`, `branch`, and `folder`, and append `updater:menuItem()` as the final menu item.
