# E-Ink Animation Lab

Experimental KOReader page-turn animation plugin for Kindle Paperwhite 4 / Rex. Version 0.3.1 applies the useful findings from E-Ink Motion / Grayscale Lab to real book pages and adds the same reusable self-update mechanism used by Motion Lab.

## New page-turn renderer

Open a book, then open **E-Ink Animation Lab**.

Use:

- **Animated next page**
- **Animated previous page**
- **Page-turn animation settings**

The new renderer uses a bowed moving page edge, a shaded paper fold, a highlight and a cast shadow. Only the moving region is refreshed. Software dithering is applied to the fold/shadow region so normal book text outside it remains untouched.

The old Plain wipe, Wipe + moving shadow and Curved edge + shadow previews are still available as **Legacy previews** for comparison.

## Page-turn animation settings

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

The three Rex HW modes use the same direct `MXCFB_SEND_UPDATE_REX` path explored by Motion Lab and require a compatible Kindle Rex device. Software modes convert only the moving fold/shadow effect to black/white before submitting A2 or DU updates.

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

## Gesture / Quick Menu use

Animation Lab registers two KOReader actions:

- **Animated page turn: next page**
- **Animated page turn: previous page**

Assign them to gestures or a Quick Menu to use the animation while reading without opening the plugin menu.

## Self-update

Version 0.3.1 includes the same reusable `pluginupdater.lua` used by E-Ink Motion Lab. **update plugin** is the final Animation Lab menu entry.

It downloads only `animationlab.koplugin` from the `main` branch of `SMUsamaShah/koplugin-experiments`, pins the update to one Git revision, verifies HTTPS and Git blob hashes, checks Lua syntax, stages the complete replacement, keeps the previous plugin folder as `.update-backup`, restores it if the final swap fails, and then offers to restart KOReader.

The updater file itself is deliberately reusable in other plugins: copy `pluginupdater.lua`, configure `repository`, `branch`, and `folder`, and append `updater:menuItem()` as the final menu item.

## Existing diagnostics

The previous moving-box benchmark, refresh comparison and synthetic page tests remain available. They use the older Animation Lab controls and are intentionally kept separate from the new Motion Lab-derived page-turn settings.
