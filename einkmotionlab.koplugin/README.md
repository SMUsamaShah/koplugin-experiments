# E-Ink Motion / Grayscale Lab

## 0.1.10: stable noise-hash rendering

Normal animations now use the bounded bit-operation hash tested on PW4.
The diagnostic found original SW Bayer rendering rising from about 175 ms at
frame 1 to 477 ms at frame 90, with no display updates. Returning to frame 1
immediately restored its early speed. The replacement stayed around 73–77 ms
across all tested positions. These are CPU-render timings, not visible FPS.

Install over the existing plugin and restart KOReader. Repeat a normal
120-frame animation with the same settings as before, then inspect/send
`einkmotionlab.log`. Each normal run now records `noise_hash=bounded_bit_hash`.
The noise pattern changes, but render modes, refresh paths and scheduling
settings retain their previous behavior. Consistent on-screen animation was
subsequently confirmed on a Kindle Paperwhite 4.

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

Open a book, then open:

**E-Ink Motion / Grayscale Lab**

For quicker repeated testing, the plugin now appears directly in the main **Tools** menu instead of **More tools**. It also registers two KOReader actions: **E-Ink Motion Lab: run everything** and **E-Ink Motion Lab: repeat last individual test**. Assign either action to a gesture or put it in a Quick Menu for one-gesture access. Individual tests keep the menu open and the last selected test is remembered.

The plugin is document-only so the experiment runs over a normal book page and restores the tested area afterwards.

## Start here

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
