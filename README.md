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

Version **0.6.0** keeps only the page-turn method that performed well on Kindle Paperwhite 4: the six-strip reveal derived from the uploaded KPW4 page-animation patch.

The animation keeps its fixed six-strip geometry and exposes only the variables that remain useful on-device:

- **Waveform:** AUTO/UI (original), DU/Fast, or A2;
- **Scheduling:** Free-running (original) or Fixed interval;
- **Strip delay:** 0–100 ms, with 40 ms matching the original patch.

Software dithering, the page-curl renderer, bounded queue scheduling, synchronized scheduling, and queue-depth controls were removed after device testing showed worse animation performance.

The original known-good baseline remains **AUTO/UI + Free-running + 40 ms + 6 strips**.

KOReader performs navigation and destination-page rendering normally. Animation Lab captures the old/new framebuffers around that repaint, reveals only the newly exposed strip on each step, suppresses the redundant queued refresh, and finishes with one full-screen UI settle.

The menu remains intentionally small: automatic-animation toggle, waveform/scheduler/delay settings, two test actions, and **update plugin** last.

See `animationlab.koplugin/README.md` for exact behavior and settings.
