# E-Ink Animation Lab

Experimental KOReader plugin for testing fast framebuffer animation techniques on E-Ink devices, especially the Kindle Paperwhite 4.

## Use

Open a book, then open **E-Ink Animation Lab**.

Start with:

- Refresh mode: **Fast / DU**
- Frames: **10**
- Frame delay: **8 ms**
- Wait for each refresh: **off**

Then try:

- **Turn ACTUAL next book page → Plain wipe**
- **Turn ACTUAL next book page → Wipe + moving shadow**
- **Turn ACTUAL next book page → Curved edge + shadow**

These commands now turn the real book page you are reading. The plugin captures the currently visible framebuffer, advances KOReader's real page/view state, renders that destination ReaderUI into an off-screen buffer, and animates between the two.

Use **Turn ACTUAL previous book page** to go back and compare another animation on the same pages.

The old generated-line tests remain under **Synthetic diagnostics**.

## Other tests

- **Moving box benchmark**: small-region animation performance.
- **Compare refresh modes**: synchronized A2, Fast/DU, UI and Partial timings.
- **Synthetic diagnostics**: controlled fake-page tests retained for debugging.

`Wait for each refresh` should stay off when judging smoothness. Turn it on only when you want serialized refresh timing; the comparison test handles that automatically.
