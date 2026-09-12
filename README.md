# KOReader Plugin Experiments

Small experimental KOReader plugins and rendering tests. These are prototypes, not production plugins.

## E-Ink Motion / Grayscale Lab

Location: `einkmotionlab.koplugin/`

This experiment targets the **Kindle Paperwhite 4 / Rex** display path. It animates grayscale content through KOReader A2/DU/AUTO paths, software and hardware dithering, direct Rex waveform ioctls, free/fixed/bounded scheduling, different region sizes, GIF playback, and an experimental GC16 pause/resume probe.

The most important PW4 finding so far is that the earlier progressive animation slowdown was largely CPU-side: the original coordinate-dependent noise hash became much slower at later coordinates. The bounded bit-operation hash fixed that and produced consistent long-run rendering times.

Diagnostics and run history are appended to `einkmotionlab.log` in KOReader's settings directory.

See `einkmotionlab.koplugin/README.md` for the complete test matrix, GIF modes, updater instructions, and warnings about direct Rex / pause-resume experiments.

## Page-turn animation plugin moved

The former `animationlab.koplugin` page-turn experiment has graduated into its own repository:

`SMUsamaShah/page-turn-animation.koplugin`

Further page-turn animation work should happen there. The plugin keeps its existing `animationlab` internal ID/settings keys for compatibility with existing installs.
