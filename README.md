# KOReader Plugin Experiments

Small experimental KOReader plugins and rendering tests. These are prototypes, not production plugins.

## E-Ink Motion / Grayscale Lab

Location: `einkmotionlab.koplugin/`

This experiment targets the **Kindle Paperwhite 4 / Rex** display path. It animates grayscale content through KOReader A2/DU/AUTO paths, software and hardware dithering, direct Rex waveform ioctls, free/fixed/bounded scheduling, different region sizes, GIF playback, and an experimental GC16 pause/resume probe.

The most important PW4 finding so far is that the earlier progressive animation slowdown was largely CPU-side: the original coordinate-dependent noise hash became much slower at later coordinates. The bounded bit-operation hash fixed that and produced consistent long-run rendering times.

Diagnostics and run history are appended to:

`einkmotionlab.log`

in KOReader's settings directory.

See `einkmotionlab.koplugin/README.md` for the complete test matrix, GIF modes, updater instructions, and warnings about direct Rex / pause-resume experiments.

## E-Ink Animation Lab

Location: `animationlab.koplugin/`

Version **0.4.0** combines the Motion Lab display experiments with the repaint architecture used by the proven KPW4 page-animation patch.

KOReader now performs page navigation and destination-page rendering normally. Animation Lab snapshots the old framebuffer in `Screen:beforePaint()`, captures the completed destination framebuffer at the first physical refresh, animates between those two buffers, suppresses the now-redundant queued refreshes for that paint cycle, and finishes with one UI-quality settle refresh.

This means standard taps, swipes and page-turn keys work through KOReader's normal code instead of being replaced by plugin navigation logic. A very small `onGotoViewRel` wrapper is retained only to record the visual direction for eligible one-page turns.

The page-curl renderer can be configured with:

- **DU or A2** waveform;
- grayscale/no dither;
- SW Bayer, stochastic, Floyd-Steinberg, Atkinson, or B/W threshold;
- Rex HW ordered, Floyd-Steinberg, or Atkinson dithering;
- Free-running, Fixed clock, Bounded EPDC queue, or Synchronized scheduling;
- target FPS, queue depth, frame count and frame delay.

The Animation Lab menu is intentionally small: automatic-animation toggle, page-turn settings, two test actions, and **update plugin** last. The old synthetic diagnostics and duplicate legacy controls are no longer part of the runtime path.

**update plugin** uses the shared `pluginupdater.lua` to update only `animationlab.koplugin` from this repository's `main` branch with staged replacement, integrity checks, backup/rollback and a restart prompt.

See `animationlab.koplugin/README.md` for detailed behavior and settings.
