#!/usr/bin/env python3
"""Make silent numbered animation takes for bounded native review checks.

Example (requires ffmpeg on PATH)::

    python3 script/make_animation_takes.py /private/tmp/animation-takes

Creates 24 MP4s: eight directions at each of 4, 8 and 12 encoded fps, each
containing exactly eight frames. ``intake.tsv`` supplies animation-take fields;
frame_rate is omitted entirely for encoded timing (do not map empty numeric
values). To exercise an item override, use
``--declared-frame-rate 8`` in a separate output folder. Import only MP4 files
and map character/action/direction from the first three ``__`` filename tokens;
apply take/hint/frame_rate from the TSV through the worker intake mapping.
This helper does not contact Checklist, launch apps or create test slots.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
import re
import shutil
import subprocess
import sys

DIRECTIONS = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")
FRAME_RATES = (4, 8, 12)
FRAME_COUNT = 8
SIDE = 256
DIGITS = {
    "1": ("010", "110", "010", "010", "111"),
    "2": ("110", "001", "010", "100", "111"),
    "3": ("110", "001", "010", "001", "110"),
    "4": ("101", "101", "111", "001", "001"),
    "5": ("111", "100", "110", "001", "110"),
    "6": ("011", "100", "110", "101", "010"),
    "7": ("111", "001", "010", "010", "010"),
    "8": ("010", "101", "010", "101", "010"),
}
COLUMNS = ("path", "character", "animation_label", "direction", "take", "hint", "frame_rate")


def safe_token(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", value) or "__" in value:
        raise argparse.ArgumentTypeError("use a filename token with letters, digits, single underscores or hyphens")
    return value


def frame_rate(value: str) -> float:
    try:
        rate = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected fps from 1 to 240") from error
    if not 1 <= rate <= 240:
        raise argparse.ArgumentTypeError("expected fps from 1 to 240")
    return rate


def encode_command(ffmpeg: str, rate: int, target: Path) -> list[str]:
    return [ffmpeg, "-v", "error", "-nostdin", "-n", "-f", "image2pipe", "-vcodec", "ppm",
            "-framerate", str(rate), "-i", "pipe:0", "-an", "-frames:v", str(FRAME_COUNT),
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(target)]


def numbered_frames(direction_index: int) -> bytes:
    """PPM stream with frame numbers 1–8 and a changing color/progress bar."""
    frames = []
    for index in range(FRAME_COUNT):
        color = (48 + direction_index * 23, 40 + index * 25, 190 - index * 17)
        pixels = bytearray(bytes(color) * (SIDE * SIDE))

        def rectangle(x: int, y: int, width: int, height: int) -> None:
            for row in range(y, y + height):
                start = (row * SIDE + x) * 3
                pixels[start:start + width * 3] = b"\xff\xff\xff" * width

        for row, cells in enumerate(DIGITS[str(index + 1)]):
            for column, cell in enumerate(cells):
                if cell == "1":
                    rectangle(80 + column * 32, 40 + row * 32, 28, 28)
        rectangle(16, 224, (index + 1) * 28, 16)
        frames.append(f"P6\n{SIDE} {SIDE}\n255\n".encode("ascii") + pixels)
    return b"".join(frames)


def generate(output: Path, *, ffmpeg: str, character: str = "SyntheticHero",
             animation_label: str = "walk", declared_frame_rate: float | None = None) -> int:
    # Requiring a new directory makes an accidental re-run refuse every overwrite,
    # including intake.tsv, before any encoder work starts.
    output.mkdir(parents=True, exist_ok=False)
    rows = []
    for rate in FRAME_RATES:
        for direction_index, direction in enumerate(DIRECTIONS):
            take = f"encoded{rate}fps"
            filename = f"{character}__{animation_label}__{direction}__{take}.mp4"
            subprocess.run(encode_command(ffmpeg, rate, output / filename),
                           input=numbered_frames(direction_index), check=True)
            rows.append(dict(path=filename, character=character, animation_label=animation_label,
                             direction=direction, take=take,
                             hint=f"Synthetic: eight numbered frames, encoded {rate} fps; one cycle {8 / rate:g} s.",
                             **({} if declared_frame_rate is None else {"frame_rate": f"{declared_frame_rate:g}"})))
    with (output / "intake.tsv").open("x", encoding="utf-8", newline="") as handle:
        columns = COLUMNS if declared_frame_rate is not None else COLUMNS[:-1]
        writer = csv.DictWriter(handle, fieldnames=columns, delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    return len(rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output", type=Path, help="new output directory; existing directories are refused")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg executable (default: PATH lookup)")
    parser.add_argument("--character", default="SyntheticHero", type=safe_token)
    parser.add_argument("--animation-label", default="walk", type=safe_token)
    parser.add_argument("--declared-frame-rate", type=frame_rate, help="optional item fps override in intake.tsv")
    arguments = parser.parse_args(argv)
    executable = shutil.which(arguments.ffmpeg)
    if executable is None:
        parser.error("ffmpeg was not found; install/provide ffmpeg before running this helper")
    try:
        count = generate(arguments.output, ffmpeg=executable, character=arguments.character,
                         animation_label=arguments.animation_label, declared_frame_rate=arguments.declared_frame_rate)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Generation failed: {error}. Any partial output is retained at {arguments.output}.", file=sys.stderr)
        return 1
    print(f"Created {count} silent eight-frame MP4 takes and intake.tsv in {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
