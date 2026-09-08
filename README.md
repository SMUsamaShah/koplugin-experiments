# KOReader Plugin Experiments

Small experimental KOReader plugins and rendering tests. These are prototypes, not production plugins.

## E-Ink Motion / Grayscale Lab

Location: `einkmotionlab.koplugin/`

This experiment targets the **Kindle Paperwhite 4 / Rex** display path. It animates a small Perlin-like grayscale field and runs the same motion through KOReader A2/DU/AUTO/Partial modes, hardware and software dithering, direct Rex waveform ioctls, queued versus synchronized updates, several patch sizes, and an experimental GC16 pause/resume probe.

Start with **Run EVERYTHING**. It saves timings incrementally to `einkmotionlab-last.txt` in KOReader's settings directory. The low-level pause probe runs last.

See `einkmotionlab.koplugin/README.md` for the full test matrix and warning about the raw Rex experiments.

## E-Ink Animation Lab

Location: `animationlab.koplugin/`

The Animation Lab tests how far fast E-Ink refreshes can be pushed on devices such as the Kindle Paperwhite 4 (10th gen). It draws directly into KOReader's framebuffer and refreshes only the dirty region.

The page-turn tests now use the **actual current and adjacent pages of the book you are reading**. The older generated-line pages are still available under **Synthetic diagnostics**.

### What to do

Open a book, then open **E-Ink Animation Lab**.

Recommended starting settings on PW4:

- Refresh mode: **Fast / DU**
- Frames: **10**
- Frame delay: **8 ms**
- Wait for each refresh: **off**

Then choose one of:

- **Turn ACTUAL next book page → Plain wipe**
- **Turn ACTUAL next book page → Wipe + moving shadow**
- **Turn ACTUAL next book page → Curved edge + shadow**

Each command genuinely advances KOReader to the next page/view and uses that real destination page for the animation. Use **Turn ACTUAL previous book page** to go backwards and try another style on the same pair of pages.

The most useful comparison is simply to flip back and forth between two pages while changing only the animation style or refresh mode.

### Other tests

- **Moving box benchmark** — tests small dirty-region animation.
- **Compare refresh modes** — measures synchronized A2, Fast/DU, UI and Partial refresh latency.
- **Synthetic diagnostics** — retains the old generated-line page tests for controlled comparisons.

### Refresh modes

- **A2**: fastest, essentially 1-bit black/white. Can ghost heavily and is poor for grayscale.
- **Fast / DU**: low-latency monochrome refresh; usually the most useful animation mode on a PW4.
- **UI**: better quality, slower.
- **Partial**: quality partial refresh, generally slower for animation.

### Wait for each refresh

Leave this **off** when judging visual smoothness, because refresh requests can pipeline.

Turn it **on** when measuring serialized per-frame latency. **Compare refresh modes** enables synchronization internally.

### What to report

For tuning a real page-turn implementation, the useful results are:

- which real-page animation looks best;
- A2 versus Fast/DU visual quality and smoothness;
- the four `ms/frame` values from **Compare refresh modes**;
- visible ghosting, tearing, or delayed regions;
- ideally a short phone video of the real-page turn tests.
