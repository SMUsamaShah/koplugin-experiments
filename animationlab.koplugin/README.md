# E-Ink Animation Lab

KOReader page-turn animation plugin for Kindle Paperwhite 4 / Rex.

Version 0.7.0 keeps the fast six-step KPW4 reveal and adds page-like reveal geometry without bringing back the slow curl renderer.

## How it works

For a normal one-page turn:

1. KOReader handles navigation and renders the destination page normally.
2. Animation Lab snapshots the old framebuffer before paint and captures the completed destination framebuffer immediately before the first physical refresh.
3. The destination is revealed in **6 temporal steps**.
4. Each step submits only **one E-Ink update**. Straight mode uses the original full-height strip. Shaped modes calculate the edge in 24 horizontal bands in RAM, then refresh one bounding rectangle around all newly revealed pixels.
5. After the animation the exact destination framebuffer is restored.
6. Normally one full-screen `refreshUI()` / AUTO settle is performed. Optionally, **Full clean refresh afterwards** replaces that settle with `refreshFull()` for stronger ghost cleanup.

## Reveal shapes

### Straight vertical (ZIP original)

The original KPW4 behavior: one vertical reveal edge moving across the page.

### Diagonal — bottom first

The bottom edge leads while the top lags, producing a diagonal page-turn edge. The lead is strongest around the middle of the animation and disappears at the end so top and bottom finish aligned.

### Curved bottom flip

A more page-like bottom-corner effect. Lower parts of the page accelerate early, with a quadratic vertical weighting that creates a curved edge. The bottom then slows relative to the top so the edge straightens and the full page finishes aligned.

The shaped modes still issue only six physical panel updates total; the extra geometry is calculated in the framebuffer before each update.

## Page-turn animation settings

### Reveal shape

- **Straight vertical (ZIP original)**
- **Diagonal — bottom first**
- **Curved bottom flip**

### Waveform

- **AUTO / UI (ZIP original)** — uses `Screen:refreshUI()` for each reveal step. On Kindle Rex this is KOReader's AUTO/UI waveform path. Default.
- **DU / Fast** — uses `Screen:refreshFast()`.
- **A2** — uses `Screen:refreshA2()`. Very fast on PW4 but device testing shows more ghosting.

### Scheduling

- **Free-running (ZIP original)** — submit a reveal step, then wait the configured delay.
- **Fixed interval** — target absolute step times from the start so rendering/submit overhead does not accumulate.

### Strip delay

Available values: 0, 5, 10, 20, 30, 40, 50, 60, 80, and 100 ms. **40 ms** matches the original KPW4 patch.

### Full clean refresh afterwards

Disabled by default.

- **Off:** after the six reveal updates, restore the exact destination and perform the original full-screen `refreshUI()` / AUTO settle.
- **On:** restore the exact destination and call full-screen `refreshFull()` instead. This is intended for aggressive modes such as A2 when ghosting matters more than the extra latency or visible flash.

## Known-good baseline

- Straight vertical
- AUTO / UI
- Free-running
- 40 ms
- Full clean refresh afterwards: off
- 6 temporal steps

## Menu

1. **Animate normal page turns**
2. **Page-turn animation settings**
   - Reveal shape
   - Waveform
   - Scheduling
   - Strip delay
   - Full clean refresh afterwards
3. **Test animated next page**
4. **Test animated previous page**
5. **update plugin**

## Normal navigation

KOReader still handles taps, swipes, page-turn keys, RTL/inverse reading order, and document navigation normally. Animation Lab only records the direction for eligible one-page turns and performs the transition later in the framebuffer repaint lifecycle.

Internal `no_page_turn` calls and multi-page jumps are left alone.

## Self-update

**update plugin** remains the final menu item. It updates only `animationlab.koplugin` from this repository's `main` branch, verifies revision/blob integrity, syntax-checks downloaded Lua, stages the replacement, retains a rollback backup, and offers to restart KOReader.
