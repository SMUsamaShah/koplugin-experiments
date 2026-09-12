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

Version **0.3.2** turns the Motion Lab research into a real page-turn renderer that can automatically animate KOReader's normal one-page navigation.

**Animate normal page turns** is enabled by default. Standard page-zone taps, horizontal page-turn swipes, page-turn keys and other `GotoViewRel ±1` navigation are intercepted and rendered with the configured animation. Search/internal no-page-turn calls, multi-page jumps and unsupported configurations fall back to KOReader normally.

The renderer uses a bowed edge, shaded page fold, highlight and cast shadow while refreshing only the moving strip. It can be configured with:

- **DU or A2** waveform;
- grayscale/no dither;
- SW Bayer, stochastic, Floyd-Steinberg, Atkinson, or B/W threshold;
- Rex HW ordered, Floyd-Steinberg, or Atkinson dithering;
- Free-running, Fixed clock, Bounded EPDC queue, or Synchronized scheduling;
- target FPS, queue depth, frame count and frame delay.

The Animation Lab menu is now intentionally small: automatic-animation toggle, page-turn settings, two manual test actions, and **update plugin** last. The old synthetic diagnostics, duplicate refresh/frame controls and legacy preview menus are hidden.

The plugin also retains KOReader actions **Animated page turn: next page** and **Animated page turn: previous page** for explicit gesture or Quick Menu assignments.

**update plugin** uses the shared `pluginupdater.lua` to update only `animationlab.koplugin` from this repository's `main` branch with staged replacement, integrity checks, backup/rollback and a restart prompt.

See `animationlab.koplugin/README.md` for detailed settings and behavior.
