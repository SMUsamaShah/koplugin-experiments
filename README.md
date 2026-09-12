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

Version **0.3.1** turns the Motion Lab research into a real page-turn renderer for the current book and adds the same reusable self-update mechanism used by Motion Lab.

The new renderer uses a bowed edge, shaded page fold, highlight and cast shadow while refreshing only the moving strip. It can be configured with:

- **DU or A2** waveform;
- grayscale/no dither;
- SW Bayer, stochastic, Floyd-Steinberg, Atkinson, or B/W threshold;
- Rex HW ordered, Floyd-Steinberg, or Atkinson dithering;
- Free-running, Fixed clock, Bounded EPDC queue, or Synchronized scheduling;
- target FPS, queue depth, frame count and frame delay.

Open **E-Ink Animation Lab → Page-turn animation settings** to change these. Use **Animated next page** or **Animated previous page** to test the selected combination.

It also registers KOReader actions **Animated page turn: next page** and **Animated page turn: previous page**, so they can be assigned to gestures or a Quick Menu for normal reading.

**update plugin**, the final Animation Lab menu item, uses the shared `pluginupdater.lua` to update only `animationlab.koplugin` from this repository's `main` branch with staged replacement, integrity checks, backup/rollback and a restart prompt.

The earlier Plain wipe / Moving shadow / Curved edge previews remain in the plugin as legacy diagnostics, along with the moving-box and refresh comparison tests.

See `animationlab.koplugin/README.md` for detailed settings, updater behavior and a suggested starting configuration.
