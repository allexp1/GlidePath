#!/usr/bin/env python3
"""
Draws the placeholder app icon.

**This is a placeholder.** It exists because App Store Connect rejects a build
whose AppIcon set has no 1024x1024 image, and the set shipped with an empty
slot - so there was no way to get a build onto TestFlight at all. It is not a
finished piece of brand design and should be replaced by one.

Generated rather than committed as a binary blob nobody can diff, and rendered
at 4x then downsampled, because PIL's drawing primitives have no antialiasing
and the diagonals look like a staircase at 1024 without it.

    python3 scripts/generate-app-icon.py

No alpha channel in the output. iOS icons must be fully opaque; a PNG with an
alpha channel is another thing App Store Connect refuses.
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

SCALE = 4
SIZE = 1024
CANVAS = SIZE * SCALE

OUTPUT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "ios/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)

BACKGROUND_TOP = (18, 22, 48)
BACKGROUND_BOTTOM = (6, 7, 16)
ROAD_SURFACE = (38, 43, 78)
ROAD_EDGE = (232, 236, 255)
CENTRE_LINE = (255, 194, 75)
RING = (255, 68, 56)


def background(draw: ImageDraw.ImageDraw) -> None:
    """A vertical gradient, one scanline at a time."""
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        colour = tuple(
            round(BACKGROUND_TOP[i] + (BACKGROUND_BOTTOM[i] - BACKGROUND_TOP[i]) * t)
            for i in range(3)
        )
        draw.line([(0, y), (CANVAS, y)], fill=colour)


def road(draw: ImageDraw.ImageDraw) -> None:
    """A carriageway receding to a vanishing point."""
    horizon = 0.42 * CANVAS
    bottom = 1.02 * CANVAS
    centre = CANVAS / 2

    near_half = 0.40 * CANVAS
    far_half = 0.030 * CANVAS

    draw.polygon(
        [
            (centre - near_half, bottom),
            (centre - far_half, horizon),
            (centre + far_half, horizon),
            (centre + near_half, bottom),
        ],
        fill=ROAD_SURFACE,
    )

    # The edges, drawn as tapering quadrilaterals rather than lines so they
    # narrow towards the vanishing point the way the road does.
    for side in (-1, 1):
        near_width = 0.030 * CANVAS
        far_width = 0.0045 * CANVAS
        draw.polygon(
            [
                (centre + side * near_half - near_width, bottom),
                (centre + side * far_half - far_width, horizon),
                (centre + side * far_half + far_width, horizon),
                (centre + side * near_half + near_width, bottom),
            ],
            fill=ROAD_EDGE,
        )

    # Centre dashes. Both the length and the width shrink with distance, which
    # is what sells the perspective; equal-sized dashes read as a ladder.
    def dash_y(t: float) -> float:
        return bottom + (horizon - bottom) * t

    def dash_half_width(t: float) -> float:
        return (1 - t) * 0.022 * CANVAS + 0.002 * CANVAS

    for index in range(5):
        near_t = 0.06 + index * 0.185
        far_t = near_t + 0.105
        if far_t > 0.98:
            break

        near_y, far_y = dash_y(near_t), dash_y(far_t)
        near_w, far_w = dash_half_width(near_t), dash_half_width(far_t)

        draw.polygon(
            [
                (centre - near_w, near_y),
                (centre - far_w, far_y),
                (centre + far_w, far_y),
                (centre + near_w, near_y),
            ],
            fill=CENTRE_LINE,
        )


def ring(draw: ImageDraw.ImageDraw) -> None:
    """The limit roundel, sat on the vanishing point: eyes on the road ahead."""
    centre = CANVAS / 2
    horizon = 0.42 * CANVAS
    radius = 0.155 * CANVAS
    width = round(0.052 * CANVAS)

    draw.ellipse(
        [centre - radius, horizon - radius, centre + radius, horizon + radius],
        outline=RING,
        width=width,
    )


def main() -> None:
    image = Image.new("RGB", (CANVAS, CANVAS), BACKGROUND_BOTTOM)
    draw = ImageDraw.Draw(image)

    background(draw)
    road(draw)
    ring(draw)

    image = image.resize((SIZE, SIZE), Image.LANCZOS)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    image.save(OUTPUT, "PNG", optimize=True)
    print(f"wrote {OUTPUT.relative_to(pathlib.Path.cwd())} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
