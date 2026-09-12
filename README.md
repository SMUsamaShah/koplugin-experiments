# KOReader Plugin Experiments

Small experimental KOReader plugins and rendering tests. These are prototypes, not production plugins.

## E-Ink Motion / Grayscale Lab

Location: `einkmotionlab.koplugin/`

This experiment targets the **Kindle Paperwhite 4 / Rex** display path. It animates grayscale content through KOReader A2/DU/AUTO paths, software and hardware dithering, direct Rex waveform ioctls, free/fixed/bounded scheduling, different region sizes, GIF playback, and an experimental GC16 pause/resume probe.

The most important PW4 finding so far is that the earlier progressive animation slowdown was largely CPU-side: the original coordinate-dependent noise hash became much slower at later coordinates. The bounded bit-operation hash fixed that and produced consistent long-run rendering times.

Diagnostics and run history are appended to `einkmotionlab.log` in KOReader's settings directory.

See `einkmotionlab.koplugin/README.md` for the complete test matrix, GIF modes, updater instructions, and warnings about direct Rex / pause-resume experiments.

## E-Ink Animation Lab

Location: `animationlab.koplugin/`

Version **0.4.2** uses KOReader's normal navigation/rendering pipeline and offers two page-turn styles:

- **KPW4 strip reveal (ZIP exact)** — the uploaded KPW4-modified page animation reproduced directly: 6 steps, 40 ms spacing, `refreshUI()` only on the newly revealed full-height strip, followed by one final full-screen UI settle. This is the default style.
- **Thin page curl** — a narrower/lower-cost replacement for the previous thick curl, retaining DU/A2, software and Rex hardware dithering, scheduling, frame count and delay controls.

The repaint hook snapshots the old framebuffer in `Screen:beforePaint()`, captures the completed destination framebuffer immediately before the first physical panel update by wrapping the dynamically dispatched `refresh*Imp` methods, runs the selected renderer, suppresses redundant queued refreshes, and restores KOReader's normal periodic-refresh cadence.

The menu remains intentionally small: automatic-animation toggle, page-turn settings, two test actions, and **update plugin** last.

See `animationlab.koplugin/README.md` for exact behavior and settings.
