# E-Ink Animation Lab

KOReader page-turn animation plugin for Kindle Paperwhite 4 / Rex. Version **0.5.0** keeps only the strip-reveal animation from the working KPW4 patch and removes the page-curl renderer completely.

## How it works

For each ordinary one-page turn, KOReader performs navigation and renders the destination page normally. Animation Lab captures the old framebuffer before paint and the completed new framebuffer immediately before the physical refresh.

The transition is the proven KPW4 method:

- **6 equal full-height strips**;
- forward turns reveal the new page from right to left;
- backward turns reveal it from left to right;
- only the **newly revealed strip** is refreshed each step;
- already revealed strips remain visible through E-Ink bistability;
- one final full-screen `refreshUI()` settles the exact destination page.

The strip count is deliberately fixed at 6 so configuration experiments do not change the known-good reveal geometry.

## Menu

1. **Animate normal page turns**
2. **Page-turn animation settings**
3. **Test animated next page**
4. **Test animated previous page**
5. **update plugin**

## Page-turn animation settings

### Dithering

- **Original grayscale / no dither** — default; matches the uploaded KPW4 patch.
- **SW Bayer**
- **SW stochastic**
- **SW Floyd-Steinberg**
- **SW Atkinson**
- **Plain B/W threshold**

Software dithering is applied only to the newly revealed strip before that strip is refreshed. The final full-screen settle restores the exact grayscale destination page.

### Scheduling

- **Free-running (ZIP original)** — submit each strip refresh, then sleep for the configured delay. This is the default and reproduces the original scheduling behavior.
- **Fixed interval** — treat Strip delay as the target interval between strip submissions; rendering time does not get added to the delay.
- **Bounded EPDC queue** — allow a configurable number of outstanding refresh markers before waiting for the oldest.
- **Synchronized** — wait for each strip refresh to complete before continuing.

### Queue depth

Used only by **Bounded EPDC queue**. Choices: 1, 2, 3, 4, 6, or 8. Default: **4**.

### Strip delay

Choices: **0, 5, 10, 20, 30, 40, 50, 60, 80, or 100 ms**.

Default: **40 ms**, matching the uploaded KPW4 patch.

## Defaults

To reproduce the original known-good animation:

- Dithering: **Original grayscale / no dither**
- Scheduling: **Free-running (ZIP original)**
- Strip delay: **40 ms**

## Self-update

**update plugin** remains the final menu entry and uses the shared `pluginupdater.lua` with staged replacement, integrity checks, backup/rollback, and a KOReader restart prompt.
