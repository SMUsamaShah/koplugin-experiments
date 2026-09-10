# E-Ink Motion / Grayscale Lab

## PW4 rendering quirk: later noise coordinates became slower (fixed in 0.1.10)

Animations initially ran quickly, then progressively slowed down. Changing
refresh waveforms, queue depth or scheduler settings did not remove the main
slowdown: it was happening inside the CPU-side noise renderer.

The original hash used large coordinate-dependent products:

```lua
local n = (ix * 73856093 + iy * 19349663 + seed * 83492791) % 2147483647
n = (n * 48271 + 1) % 2147483647
return n / 2147483647
```

As the animation advances, its noise coordinates grow. Rendering those later
coordinates was much more expensive on the PW4, even though the number of
rendered blocks stayed the same.

### How we isolated it

We rendered selected animation positions into a private memory buffer with
**no display updates**, then jumped back to the starting position. At 512 × 512
with 2 px SW Bayer blocks, the device measured:

| Logical frame | Original hash | Replacement hash |
| --- | ---: | ---: |
| 1 | 175.68 ms | 73.92 ms |
| 90 | 476.70 ms | 75.53 ms |
| 120 | 430.81 ms | 73.13 ms |
| Back to 1 | 174.60 ms | 73.89 ms |

Each value is the mean wall time of three renders. Process CPU time closely
matched wall time, and every frequency sample reported 996 MHz. Returning to
frame 1 immediately restored the original renderer's speed. This isolated a
coordinate-dependent rendering cost without an e-ink queue involved.
Short 24-frame tests could miss the later slowdown entirely.

### Fix and limits of the finding

Version **0.1.10** replaces the hash with explicit 32-bit bit-operation mixing,
avoiding the growing large-product arithmetic. The replacement stayed around
73–77 ms across all tested Bayer positions; consistent on-screen animation was
then confirmed on the PW4. The noise pattern changes, while refresh paths,
render modes and scheduler settings retain their previous behavior. Normal run
logs identify the replacement with `noise_hash=bounded_bit_hash`.

**The exact LuaJIT mechanism is still unconfirmed.** Intermediate expressions
crossing the signed 32-bit range correlate with the original slowdown, making
integer overflow guards or changes in compiled execution paths plausible.
This is not proof of arithmetic corruption or a universal LuaJIT bug. The large
slowdown did not reproduce in a local desktop LuaJIT test.

**Practical lesson:** measure image generation separately from refresh calls,
and benchmark late animation coordinates as well as early ones. A rendering
bottleneck can look like an e-ink refresh limitation. These timings describe
rendering cost, not visible display FPS.

## Renderer diagnostic

Install this folder over the existing plugin and restart KOReader. With a book
open, select **Tools → E-Ink Motion / Grayscale Lab → Diagnose renderer (screen
stays still)**. Wait for the result dialog; the screen intentionally stays still
during the calculation. Send the updated `einkmotionlab.log` from KOReader's
settings directory.

This compares the original noise hash and an alternative bounded bit-operation
hash in a private 512 × 512 memory buffer. Both gray (8 px blocks) and SW Bayer
(2 px blocks) visit logical frames 1, 40, 60, 90, 120, 1, 120, 1, three renders
per position after two early-frame warmups. It records wall time, process CPU
time, JIT status, CPU frequency and memory. There are no screen refresh calls
inside the diagnostic. The alternative changes the noise pattern. Private
renderer copies may compile differently from the normal animation loop, so
negative results do not conclusively exclude a JIT problem.

The diagnostic retains the old renderer for comparison; normal animations use
the replacement. This build is based on main commit
`4be836858db88f9022521fbd14638bc4a1caa262` plus the diagnostic and hash changes.

Experimental KOReader plugin for probing how smoothly a small region can animate on a Kindle Paperwhite 4 (Rex).

It draws a centered **Perlin-like moving grayscale field** and runs the same visual through different waveform, dithering, queuing, and region-size strategies. The goal is not accurate grayscale reproduction; it is to find refresh paths that *look* fluid for organic grayscale motion.

## Install

Copy `einkmotionlab.koplugin` into KOReader's `plugins` directory and restart KOReader.

After installing 0.1.14 once, use **update plugin**, the last entry in this
plugin's menu, for future updates. It connects through KOReader's Wi-Fi flow,
downloads only `einkmotionlab.koplugin` from this repository's `main` branch,
and offers to restart KOReader. No SSH, Git, release ZIP, or GitHub login is
needed. Tap the download dialog to cancel.

Downloads use one pinned revision, verified HTTPS, Git blob checksums, and Lua
syntax checks. Files are staged before the installed folder is replaced; a
failed installation attempts to restore the original. The previous folder is
retained as `einkmotionlab.koplugin.update-backup`, replaced on the next
successful staging. Settings and logs in KOReader's settings directory persist.

Open a book, then open:

**E-Ink Motion / Grayscale Lab**

For quicker repeated testing, the plugin now appears directly in the main **Tools** menu instead of **More tools**. It also registers two KOReader actions: **E-Ink Motion Lab: run everything** and **E-Ink Motion Lab: repeat last individual test**. Assign either action to a gesture or put it in a Quick Menu for one-gesture access. Individual tests keep the menu open and the last selected test is remembered.

The plugin is document-only so the experiment runs over a normal book page and restores the tested area afterwards.

### Reuse the updater in another plugin

Copy **`pluginupdater.lua`** into that plugin. Create one updater instance and
append its menu item last:

```lua
-- plugin_dir is the directory containing this plugin's main.lua, with a trailing slash.
local updater = dofile(plugin_dir .. "pluginupdater.lua").new{
    repository = "owner/repository",
    branch = "main",
    folder = "example.koplugin", -- "" if plugin files are at the repository root
}
items[#items + 1] = updater:menuItem()
```

The destination is inferred from the updater file's location. Optional
`can_update = function() ... end` disables updates while the plugin is busy.
Keep user-created data outside the plugin folder: this is a complete folder
replacement, including removal of obsolete files. The updater itself is updated
too. Public repositories and ordinary files/subdirectories are supported, up to
512 files, 8 MiB per file and 32 MiB total; symlinks and submodules are rejected.
GitHub rate limits and download failures leave the installed copy in place.
Updater regression checks: run `python tests/test_plugin_updater.py` with
Python's `lupa` package installed. These use temporary folders and mocked
network/UI calls; verify the Wi-Fi and restart flow on the device too.

## Start here

### GIF playback (0.1.14)

Open **Tools → E-Ink Motion / Grayscale Lab → Run GIF test**:

- **Play demo GIF** starts the included moving-dot and grayscale-wave animation.
- **Choose and play GIF…** opens a file picker; tap a GIF on your Kindle.
- **Replay last GIF** repeats the last successfully loaded file.
- **Play last GIF with…** selects a mode and immediately replays the last GIF.

Playback keeps the menu open, like the noise tests, so you can try another GIF
or mode without reopening it.

The image fits inside **Patch size** with its aspect ratio preserved. Tap
anywhere (or press Back) to stop and restore the page. There is a preparation
pause before playback: all frames are decoded, composited, scaled and converted
once, so playback only copies cached frames and requests refreshes.

**GIF refresh mode** now includes every mode from **Run one test**, using the
same refresh API, waveform and hardware-dither parameters. On PW4/Rex there are
**22 modes: the 14 noise-test modes plus eight additional comparisons**.

| Group | Modes |
| --- | --- |
| KOReader paths from noise tests | A2 gray, A2 SW Bayer, A2 SW stochastic; DU gray, DU SW Bayer; UI/AUTO |
| Raw Rex paths from noise tests | AUTO gray/ordered; A2 ordered/Floyd–Steinberg/Atkinson; DU ordered; A2 and DU ordered burst variants |
| Additional software comparisons | DU SW stochastic; A2/DU SW Floyd–Steinberg; A2/DU SW Atkinson; A2/DU plain B/W threshold |
| Additional grayscale reference | Raw GC16 synchronized |

Raw modes appear only when the existing Rex capability check passes. Other
devices retain the noise test's synchronized Partial fallback and the software
comparisons. Existing saved A2/Bayer, DU/Bayer and AUTO/gray selections migrate
automatically.

All **SW** conversions are prepared and cached before playback. Stochastic
dithering uses a fixed spatial mask, so the mask does not change between frames.
Software error diffusion is recomputed per frame and may produce changing dot
patterns as image content moves; compare it with Bayer for temporal stability.
Hardware-dither modes receive grayscale frames and let the driver convert them.
GIF software dithering works at 1 px; noise block-size settings do not apply.
Scaling uses nearest-neighbour sampling.

**GIF timing** uses the file's individual frame delays by default, or the
existing **Fixed-clock target FPS** setting. Missing/zero delays use 100 ms;
nonzero delays below 20 ms use 20 ms. **GIF repetitions** selects 1, 3 (default),
or 10 plays, overriding the file's loop flag.

Paced GIF modes combine clock timing with the existing **Bounded queue depth**
limit, checked before copying/submitting another frame, and skip obsolete frames
if playback falls behind. The noise scheduler and extra frame-delay settings do
not apply. Submission timing is not a measurement of visible FPS.

The inherited **0 ms burst** modes submit every GIF frame as quickly as the
bounded queue allows, overriding GIF/FPS timing. A 1 ms yield between submissions
keeps tap-to-stop responsive; these are not unbounded hardware queue floods.
They play the chosen number of GIF repetitions rather than the noise tests'
fixed 24-frame burst length. **Synchronized** modes wait for each completed
update and preserve every source frame, slowing playback when necessary rather
than skipping frames; the selected timing sets a minimum hold time.

Preparation time, cache size, exact mode/API/waveform/dither settings,
submitted/skipped frames and early/mid/late timings append to
`einkmotionlab.log`. Transparency is composited on white;
partial frames, local palettes and background/previous-frame disposal are
handled sequentially. The original noise tests remain available.

Files are limited to 8 MiB, 512 frames, a 4-megapixel source canvas, 32 MiB of
decoded indexed pixels and a 32 MiB playback cache. If the cache is too large,
reduce **Patch size** or choose a shorter GIF.

Developer regression checks: install Python's `lupa` package and run
`python tests/test_gif_modes.py` from the repository root. These check catalog
parity, refresh routing, software conversion, timing and cleanup without a
Kindle; optical refresh behavior still requires device testing.

### Noise and refresh experiments

Use:

**Run EVERYTHING (recommended first test)**

For the first comparison, use normal (non-inverted) day mode so the raw Rex tests and KOReader-managed tests are easier to compare.

Default settings are:

- patch: 96 x 96 px
- 24 frames per normal visual test
- 8 ms requested delay between submissions
- 4 px grayscale render blocks
- software dither tests use finer 2 px blocks

All diagnostics now append to one plain-text history file, `einkmotionlab.log`, in KOReader's settings directory. Every visual test records all current Motion Lab settings, the final timing result, start/end system state, and sparse CPU/temperature telemetry. Suite checkpoints are appended incrementally so earlier data survives even if a later experimental probe misbehaves.

A phone video of the patch during the run is much more useful than timings alone, because the interesting question is which mode *looks* smooth.

## What it tests

### KOReader refresh paths

- A2 with grayscale input
- A2 + software Bayer black/white dithering
- A2 + software stochastic black/white dithering
- DU/Fast with grayscale input
- DU + software Bayer black/white dithering
- UI/AUTO

The software-dither modes deliberately use only black and white physical pixels. At 300 dpi the fine pattern can visually average into moving gray without asking the panel for accurate intermediate gray states.

### Direct PW4/Rex refresh paths

On a Kindle Rex device the plugin also bypasses KOReader's normal refresh scheduling and submits `MXCFB_SEND_UPDATE_REX` directly.

It compares:

- AUTO queued
- AUTO + ordered dithering
- A2 + ordered dithering
- A2 0 ms burst submission
- A2 + Floyd-Steinberg dithering
- A2 + Atkinson dithering
- DU + ordered dithering
- DU 0 ms burst submission

The raw tests are intentionally aggressive. They are experiments, not recommended rendering policy for normal KOReader use.

### Region-size sweep

The plugin repeats selected animations at:

- 32 x 32
- 64 x 64
- 96 x 96
- 128 x 128
- 192 x 192

The timing report includes both wall time and Lua-side noise-render time, so CPU rendering cost can be separated somewhat from E-Ink refresh behavior.

### PW4 capability probe

The plugin asks the framebuffer driver for:

- device / Rex detection
- framebuffer bits per pixel
- waveform type (4-bit or 5-bit if reported)
- EPDC temperature

### GC16 pause/resume probe

There are two experimental tests:

- **Probe GC16 pause/resume ioctl (80 ms)**
- **GC16 pause timing sweep (20..140 ms)**

A trial starts a white-to-black GC16 update, waits for the selected delay, calls `MXCFB_SET_PAUSE`, holds, then tries `MXCFB_SET_RESUME`.

The Kindle public framebuffer header exposes these ioctls but does not document enough behavior to assume they work as desired on Rex. Treat this as a probe.

If the patch visibly holds at an intermediate shade during the pause period, that is the interesting result: it suggests we can investigate controlling waveform progress rather than only requesting final gray values.

## Important warning

The normal KOReader tests are straightforward framebuffer experiments. The **raw Rex** and especially **pause/resume** tests deliberately bypass some of KOReader's safety/scheduling behavior.

A failed pause/resume experiment could leave the display path temporarily stuck or visually dirty. The plugin tries to recover and restore the page, but be prepared to restart KOReader (or reboot the Kindle if necessary).

`Run EVERYTHING` performs the pause probe **last**.

## What to send back after testing

The most useful data is:

1. a phone video of **Run EVERYTHING**;
2. `einkmotionlab.log`;
3. whether any mode looked genuinely fluid;
4. whether the 32/64/128 px tests differed noticeably;
5. whether the GC16 pause test visibly froze on an intermediate shade;
6. any KOReader crash log if a raw mode fails.

Once we know which path is promising, the plugin can be narrowed into a faster continuous animation test instead of spending time cycling through diagnostics.

## Large-patch / long-run stress testing

For the promising software Bayer modes, the menu now supports patch sizes up to **1024 x 1024** and run lengths up to **960 frames**. A separate **SW Bayer block size** control (2/4/8/16 px) lets you trade visual fineness for much lower Lua rendering cost when testing large regions. Start at 2 px for appearance; if large patches become CPU-bound, try 4 or 8 px to isolate E-Ink/EPDC update performance.

## SW Bayer scheduling diagnostics

The A2/DU software-Bayer tests have three scheduling modes: **Free-running**, **Fixed clock** (absolute deadlines and dropped obsolete logical frames), and **Bounded EPDC queue** (caps outstanding updates and waits on the oldest marker). Target FPS and queue depth are configurable.

The result dialog still reports the useful early/middle/late render, refresh, wait and interval averages. There is no longer a per-frame TSV. Instead, `einkmotionlab.log` stores one readable block per test with every current setting, the final result, CPU frequency/governor/range, thermal readings, load and available memory at start/end, plus sparse CPU-frequency samples at frame 1, every 10 submitted frames, and the final frame. Temperature is measured only in the full system snapshots immediately before and after the animation, since it changes slowly and does not need per-10-frame probing. Samples are collected in memory and written only after the animation to avoid disk I/O affecting the test. The SW Bayer block size is also resolved at execution time so changing it immediately affects already-open test menus.
