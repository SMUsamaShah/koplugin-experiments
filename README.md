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

Version **0.7.0** keeps the fast six-step reveal derived from the uploaded KPW4 page-animation patch and adds page-like reveal geometry without restoring the slower curl renderer.

Available reveal shapes:

- **Straight vertical** — original KPW4 strip reveal;
- **Diagonal — bottom first** — bottom leads, top lags, then both converge at the end;
- **Curved bottom flip** — lower bands accelerate early with a curved edge, then slow so the page finishes aligned.

All three shapes still use only **six physical E-Ink updates** per turn. The shaped modes calculate the edge in horizontal framebuffer bands and submit one bounding-rectangle update per temporal step.

Useful on-device controls are:

- **Waveform:** AUTO/UI, DU/Fast, or A2;
- **Scheduling:** Free-running or Fixed interval;
- **Strip delay:** 0–100 ms, with 40 ms matching the original patch;
- **Full clean refresh afterwards:** optional `refreshFull()` cleanup for aggressive modes such as A2. When disabled, the normal final `refreshUI()` / AUTO settle remains.

The original known-good baseline remains **Straight + AUTO/UI + Free-running + 40 ms** with full clean refresh disabled.

KOReader performs navigation and destination-page rendering normally. Animation Lab captures the old/new framebuffers around that repaint, performs the reveal, suppresses the redundant queued refresh, and restores the exact final page.

See `animationlab.koplugin/README.md` for exact behavior and settings.
