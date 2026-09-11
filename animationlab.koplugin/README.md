# E-Ink Animation Lab

Experimental KOReader page-turn animation plugin for Kindle Paperwhite 4 / Rex. Version 0.3.0 applies the useful findings from E-Ink Motion / Grayscale Lab to real book pages.

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

Version 0.3.0 registers two KOReader actions:

- **Animated page turn: next page**
- **Animated page turn: previous page**

Assign them to gestures or a Quick Menu to use the animation while reading without opening the plugin menu.

## Existing diagnostics

The previous moving-box benchmark, refresh comparison and synthetic page tests remain available. They use the older Animation Lab controls and are intentionally kept separate from the new Motion Lab-derived page-turn settings.
