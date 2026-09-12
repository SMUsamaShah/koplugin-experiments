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

Version **0.5.0** keeps only the KPW4 six-strip reveal from the uploaded working patch. The page-curl renderer and style selector have been removed completely.

KOReader still performs normal page navigation and destination-page rendering. Animation Lab captures the old and new framebuffers around that repaint, then reveals the destination in **6 equal full-height strips**, refreshing only the newly exposed strip at each step. A final full-screen `refreshUI()` settles the exact page.

The strip reveal now supports:

- **Original grayscale / no dither**, SW Bayer, stochastic, Floyd-Steinberg, Atkinson, and plain threshold dithering;
- **Free-running (ZIP original)**, Fixed interval, Bounded EPDC queue, and Synchronized scheduling;
- configurable bounded-queue depth;
- configurable strip delay from 0 to 100 ms.

The original uploaded behavior remains the default: no dithering, free-running scheduling, **40 ms** strip delay, and six strips.

The menu remains intentionally small: automatic-animation toggle, page-turn settings, two test actions, and **update plugin** last.

See `animationlab.koplugin/README.md` for exact behavior and settings.
