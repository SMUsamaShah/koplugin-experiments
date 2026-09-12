# E-Ink Animation Lab

KOReader page-turn animation plugin for Kindle Paperwhite 4 / Rex.

Version 0.6.0 keeps only the page-turn approach that performed well on the PW4: the six-strip reveal from the uploaded KPW4 page-animation patch.

The curl renderer, software dithering experiments, bounded queue scheduler, synchronized scheduler, and queue-depth setting have been removed from the runtime.

## How it works

For a normal one-page turn:

1. KOReader handles navigation and renders the destination page normally.
2. Animation Lab snapshots the old framebuffer before paint and captures the completed destination framebuffer immediately before the first physical refresh.
3. The destination is revealed in **6 equal full-height strips**.
4. Only the newly revealed strip is physically refreshed on each step; previous strips persist through E-Ink bistability.
5. One final full-screen `refreshUI()` settles the exact destination page.

The six-strip geometry is fixed so waveform, scheduling, and delay can be compared without changing the animation itself.

## Page-turn animation settings

### Waveform

- **AUTO / UI (ZIP original)** — uses `Screen:refreshUI()` for each strip. On Kindle Rex this is KOReader's AUTO/UI waveform path. This is the default.
- **DU / Fast** — uses `Screen:refreshFast()` for each strip.
- **A2** — uses `Screen:refreshA2()` for each strip.

A new setting key, `animationlab_strip_waveform`, is used intentionally so older curl-era waveform settings cannot silently force DU after upgrading. The first run of 0.6.0 therefore starts on AUTO unless you explicitly change it.

### Scheduling

- **Free-running (ZIP original)** — submit a strip, then wait the configured delay before the next strip.
- **Fixed interval** — target absolute strip times from the start of the animation so render/submit overhead does not accumulate into later frames.

The bounded queue and synchronized modes were removed because device testing showed them to perform worse than free-running and fixed interval.

### Strip delay

Available values:

- 0 ms
- 5 ms
- 10 ms
- 20 ms
- 30 ms
- **40 ms (ZIP original)**
- 50 ms
- 60 ms
- 80 ms
- 100 ms

The original KPW4 patch baseline is therefore:

- **AUTO / UI**
- **Free-running**
- **40 ms**
- **6 strips**

## Menu

The menu contains only:

1. **Animate normal page turns**
2. **Page-turn animation settings**
   - Waveform
   - Scheduling
   - Strip delay
3. **Test animated next page**
4. **Test animated previous page**
5. **update plugin**

## Normal navigation

KOReader still handles taps, swipes, page-turn keys, RTL/inverse reading order, and document navigation normally. Animation Lab only records the direction for eligible one-page turns and performs the transition later in the framebuffer repaint lifecycle.

Internal `no_page_turn` calls and multi-page jumps are left alone.

## Self-update

**update plugin** remains the final menu item. It updates only `animationlab.koplugin` from this repository's `main` branch, verifies revision/blob integrity, syntax-checks downloaded Lua, stages the replacement, retains a rollback backup, and offers to restart KOReader.
