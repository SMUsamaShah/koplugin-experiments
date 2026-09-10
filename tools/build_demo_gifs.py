#!/usr/bin/env python3
"""Build the small grayscale GIFs shipped with E-Ink Motion Lab.

The source images deliberately stay soft and mid-gray.  The Kindle test modes
can then show how each refresh path handles real grayscale motion without
starting from a harsh black-and-white shape.

Run from the repository root:

    python tools/build_demo_gifs.py
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image


WIDTH = 128
HEIGHT = 96
FRAME_COUNT = 40
FRAME_DELAY_MS = 50
PALETTE_LEVELS = 64


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def smoothstep(value: float) -> float:
    value = clamp(value)
    return value * value * (3.0 - 2.0 * value)


def smooth_transition(distance: float, radius: float, feather: float) -> float:
    """Return a soft-edged disk alpha, with 1 inside and 0 outside."""

    edge = (distance - (radius - feather)) / (2.0 * feather)
    return 1.0 - smoothstep(edge)


def lattice_value(x: int, y: int, seed: int) -> float:
    """A deterministic 32-bit lattice value for the cloud animation."""

    value = (x * 374761393 + y * 668265263 + seed * 1442695041) & 0xFFFFFFFF
    value = ((value ^ (value >> 13)) * 1274126177) & 0xFFFFFFFF
    value ^= value >> 16
    return (value & 0xFFFFFFFF) / 4294967295.0


def value_noise(x: float, y: float, seed: int) -> float:
    """Bilinear value noise with smooth interpolation between lattice points."""

    x0 = math.floor(x)
    y0 = math.floor(y)
    tx = smoothstep(x - x0)
    ty = smoothstep(y - y0)

    top = (
        lattice_value(x0, y0, seed) * (1.0 - tx)
        + lattice_value(x0 + 1, y0, seed) * tx
    )
    bottom = (
        lattice_value(x0, y0 + 1, seed) * (1.0 - tx)
        + lattice_value(x0 + 1, y0 + 1, seed) * tx
    )
    return top * (1.0 - ty) + bottom * ty


def render_frame(function) -> Image.Image:
    pixels = bytearray(WIDTH * HEIGHT)
    index = 0
    for y in range(HEIGHT):
        for x in range(WIDTH):
            pixels[index] = int(clamp(function(x, y), 0.0, 255.0) + 0.5)
            index += 1
    return Image.frombytes("L", (WIDTH, HEIGHT), bytes(pixels))


def cloud_frames() -> list[Image.Image]:
    frames = []
    for frame in range(FRAME_COUNT):
        drift_x = frame * 0.075
        drift_y = frame * 0.043

        def pixel(x: int, y: int) -> float:
            # Three smooth scales give the field a soft, Perlin-like look.
            coarse = value_noise(x / 38.0 + drift_x, y / 31.0 + drift_y, 17)
            medium = value_noise(x / 19.0 + drift_x * 1.7, y / 16.0 + drift_y * 1.5, 41)
            fine = value_noise(x / 9.0 + drift_x * 2.4, y / 8.0 + drift_y * 2.0, 73)
            value = 0.58 * coarse + 0.29 * medium + 0.13 * fine
            return 70.0 + 125.0 * value

        frames.append(render_frame(pixel))
    return frames


def wave_frames() -> list[Image.Image]:
    frames = []
    for frame in range(FRAME_COUNT):
        phase = 2.0 * math.pi * frame / FRAME_COUNT
        travel = frame * 2.3

        def pixel(x: int, y: int) -> float:
            # Broad overlapping waves avoid a hard edge while still making
            # the movement easy to see on a low-refresh grayscale display.
            horizontal = math.sin((x - travel) / 20.0 + 0.65 * math.sin(y / 19.0))
            diagonal = math.sin((x + y * 0.55) / 31.0 - phase * 0.75)
            vertical = math.sin(y / 17.0 + phase * 0.45)
            value = 0.52 + 0.28 * horizontal + 0.13 * diagonal + 0.07 * vertical
            return 58.0 + 145.0 * value

        frames.append(render_frame(pixel))
    return frames


def orbit_frames() -> list[Image.Image]:
    frames = []
    center_x, center_y = WIDTH / 2.0, HEIGHT / 2.0
    large_radius = 32.0
    orbit_radius = 19.0

    for frame in range(FRAME_COUNT):
        # In image coordinates (where y increases downward), increasing the
        # angle travels top -> right -> bottom -> left: clockwise.
        angle = 2.0 * math.pi * frame / FRAME_COUNT - math.pi / 2.0
        spot_x = center_x + orbit_radius * math.cos(angle)
        spot_y = center_y + orbit_radius * math.sin(angle)

        def pixel(x: int, y: int) -> float:
            distance = math.hypot(x - center_x, y - center_y)
            large_alpha = smooth_transition(distance, large_radius, 4.5)

            background = (
                126.0
                + 4.0 * math.sin(x / 25.0 + frame * 0.08)
                + 3.0 * math.sin(y / 19.0 - frame * 0.06)
            )
            # A gently shaded disk with a feathered boundary.
            large_value = 103.0 + 42.0 * (1.0 - clamp(distance / large_radius))
            value = background * (1.0 - large_alpha) + large_value * large_alpha

            # A Gaussian spot is a circular gradient rather than a clipped
            # ball.  Its broad halo helps it remain visible after dithering.
            spot_distance = math.hypot(x - spot_x, y - spot_y)
            spot = math.exp(-0.5 * (spot_distance / 5.8) ** 2)
            halo = math.exp(-0.5 * (spot_distance / 11.0) ** 2)
            return value + 49.0 * spot + 10.0 * halo

        frames.append(render_frame(pixel))
    return frames


def ripple_frames() -> list[Image.Image]:
    frames = []
    center_x, center_y = WIDTH / 2.0, HEIGHT / 2.0
    for frame in range(FRAME_COUNT):
        phase = 2.0 * math.pi * frame / FRAME_COUNT

        def pixel(x: int, y: int) -> float:
            distance = math.hypot(x - center_x, y - center_y)
            envelope = math.exp(-distance / 57.0)
            ripple = math.sin(distance / 6.5 - phase * 1.8)
            slow_field = math.sin((x + y) / 28.0 + phase * 0.4)
            return 128.0 + 47.0 * ripple * envelope + 9.0 * slow_field

        frames.append(render_frame(pixel))
    return frames


def to_fixed_palette(frame: Image.Image) -> Image.Image:
    # A fixed grayscale palette keeps the source animation from changing its
    # palette between frames. Hardware/software GIF test modes can then apply
    # their own dithering consistently.
    indices = bytes(
        min(PALETTE_LEVELS - 1, (value * (PALETTE_LEVELS - 1) + 127) // 255)
        for value in frame.tobytes()
    )
    indexed = Image.frombytes("P", frame.size, indices)
    palette = []
    for level in range(PALETTE_LEVELS):
        gray = round(level * 255 / (PALETTE_LEVELS - 1))
        palette.extend((gray, gray, gray))
    palette.extend([0] * (768 - len(palette)))
    indexed.putpalette(palette)
    return indexed


def save_animation(frames: list[Image.Image], path: Path) -> None:
    indexed = [to_fixed_palette(frame) for frame in frames]
    indexed[0].save(
        path,
        save_all=True,
        append_images=indexed[1:],
        duration=FRAME_DELAY_MS,
        loop=0,
        disposal=2,
        optimize=False,
    )


def build(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    animations = {
        "demo_clouds.gif": cloud_frames(),
        "demo_wave.gif": wave_frames(),
        "demo_orbit.gif": orbit_frames(),
        "demo_ripple.gif": ripple_frames(),
    }
    for name, frames in animations.items():
        path = output_dir / name
        save_animation(frames, path)
        print(f"{path}: {path.stat().st_size} bytes, {len(frames)} frames")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "einkmotionlab.koplugin",
    )
    args = parser.parse_args()
    build(args.output_dir)


if __name__ == "__main__":
    main()