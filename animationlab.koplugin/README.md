# E-Ink Animation Lab

KOReader page-turn animation plugin for Kindle Paperwhite 4 / Rex.

Version 0.4.2 has two selectable animation styles and uses KOReader's normal page navigation/rendering path. The plugin snapshots the old framebuffer before paint, captures the completed destination framebuffer at the first physical refresh, runs the selected animation, suppresses the redundant queued refreshes for that paint cycle, and finishes with one full-screen UI-quality settle.

## Animation styles

Open **E-Ink Animation Lab → Page-turn animation settings → Animation style**.

### KPW4 strip reveal (ZIP exact)

This is the KPW4-modified animation from the uploaded `koreader-page-animation.zip`, reproduced directly inside the plugin:

- 6 equal progress steps;
- 40 ms delay between steps;
- forward turns reveal the destination from right to left;
- backward turns reveal it from left to right;
- only the newly revealed full-height strip is refreshed with `refreshUI()` on each step;
- previously revealed pixels are left alone and persist through E-Ink bistability;
- one final full-screen `refreshUI()` settles the destination page.

The strip mode deliberately ignores the curl waveform/dither/scheduler controls so it stays comparable to the proven KPW4 patch.

**This is the default style in v0.4.2.**

### Thin page curl

The old thick curl renderer has been replaced by a substantially thinner and cheaper version:

- curve bow reduced from about 3% to 1.2% of screen width;
- fold width reduced from about 7% to 2.8%;
- shadow reduced from about 4% to 1.4%;
- fewer tonal slices are drawn for the fold/shadow;
- larger horizontal bands reduce CPU drawing work;
- only the moving dirty strip is refreshed.

The thin curl retains the Motion Lab controls for DU/A2, software or Rex hardware dithering, free/fixed/bounded/synchronized scheduling, target FPS, queue depth, frame count and frame delay.

## Normal page turns

**Animate normal page turns** is enabled by default.

KOReader still handles taps, swipes, keys, RTL/inverse reading order and document navigation normally. A small `onGotoViewRel` wrapper records only the direction for eligible one-page turns. The actual animation happens later in the framebuffer repaint lifecycle after KOReader has rendered the destination page.

Internal `no_page_turn` calls and multi-page jumps are left alone.

## Refresh interception

KOReader's `UIManager` caches references to the public `Screen.refresh*` functions when it loads, so replacing those methods later from a plugin does not reliably intercept repaint. Animation Lab instead wraps the dynamically dispatched `refresh*Imp` methods, which are still reached immediately before the panel update.

## Menu

The menu contains only:

1. **Animate normal page turns**
2. **Page-turn animation settings**
3. **Test animated next page**
4. **Test animated previous page**
5. **update plugin**

## Self-update

**update plugin** is the final menu entry and uses the same reusable `pluginupdater.lua` as E-Ink Motion Lab. It updates only `animationlab.koplugin` from the repository's `main` branch, verifies the Git revision and downloaded blobs, checks Lua syntax, stages the replacement, keeps a rollback backup, and offers to restart KOReader.
