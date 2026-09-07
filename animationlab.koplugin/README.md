# E-Ink Animation Lab

Experimental KOReader plugin for testing fast framebuffer animation techniques on E-Ink devices, especially the Kindle Paperwhite 4.

## Install

Copy this whole folder to:

`koreader/plugins/animationlab.koplugin/`

Then restart KOReader and open a book. The plugin appears as **E-Ink Animation Lab** in the main menu's tools/plugins area.

## Suggested PW4 settings

- Refresh mode: Fast / DU
- Frames: 10
- Frame delay: 8 ms
- Wait for each refresh: off

Run **Moving box benchmark**, then the three **Page-turn previews**, then **Compare refresh modes**.

`Wait for each refresh` should stay off for judging smoothness and be enabled only when you want serialized timing. The comparison test handles synchronization itself.

The tests restore the original framebuffer after each run and do not modify the document.
