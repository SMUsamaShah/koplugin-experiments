# KOReader Plugin Experiments

Small experimental KOReader plugins and rendering tests. These are prototypes, not production plugins.

## E-Ink Animation Lab

Location: `animationlab.koplugin/`

The Animation Lab is for testing how far fast E-Ink refreshes can be pushed on devices such as the Kindle Paperwhite 4 (10th gen). It draws directly into KOReader's framebuffer and refreshes only the dirty region, similar to the low-latency path used by Finger Ink.

### Install

1. Copy the entire `animationlab.koplugin` folder into KOReader's `plugins` directory.
2. Restart KOReader completely.
3. Open a book.
4. Open KOReader's main menu and choose **E-Ink Animation Lab** under the tools/plugins area.

The folder on the Kindle should look like:

```text
koreader/
  plugins/
    animationlab.koplugin/
      _meta.lua
      main.lua
      README.md
```

Do not copy only the files into `plugins`; keep the `.koplugin` folder itself.

### Recommended first test on Paperwhite 4

Set:

- Refresh mode: **Fast / DU**
- Frames: **10**
- Frame delay: **8 ms**
- Wait for each refresh: **off**

Then run, in this order:

1. **Moving box benchmark** — simplest animation test; only a small dirty rectangle moves.
2. **Page-turn previews → Plain wipe** — baseline strip/reveal animation.
3. **Page-turn previews → Wipe + moving shadow** — adds a moving fold/shadow cue.
4. **Page-turn previews → Curved edge + shadow** — approximates a bowed turning page using horizontal bands.
5. **Compare refresh modes** — measures synchronized A2, Fast/DU, UI and Partial refresh latency.

### Refresh modes

- **A2**: fastest, essentially 1-bit black/white. Can ghost heavily and is poor for grayscale.
- **Fast / DU**: low-latency monochrome refresh; usually the most useful animation mode on a PW4.
- **UI**: better quality, slower.
- **Partial**: quality partial refresh, slowest of the animation-oriented choices here.

### Wait for each refresh

Normally leave this **off** when judging visual smoothness, because refresh requests can pipeline.

Turn it **on** when measuring real per-frame latency. The comparison test enables synchronization internally so the timings are meaningful.

### What to report

The most useful results from a real PW4 are:

- the four `ms/frame` values from **Compare refresh modes**;
- which page-turn preview looks best;
- whether A2 or Fast/DU looks smoother;
- visible ghosting or black/white artifacts;
- ideally, a short video of the three page-turn previews.

The goal is to use those results to build a real gesture-coupled KOReader page-turn animation rather than guessing at the best waveform and frame count.
