#!/usr/bin/env python3
"""Lay a pane capture out for the hint overlay.

The overlay pane is not the pane we captured: depending on the tab layout it
can cover the whole tab area. We read the tab layout to work out where the
captured pane sits inside that area, pad the capture so every match lands on
the same cell the user was already looking at, then clip it to the overlay.
"""

from __future__ import annotations

import argparse
import json
import sys
import unicodedata


def display_width(text: str) -> int:
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)


def clip(line: str, cols: int) -> str:
    if display_width(line) <= cols:
        return line
    out: list[str] = []
    width = 0
    for ch in line:
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if width + w > cols:
            break
        out.append(ch)
        width += w
    return "".join(out)


def offsets(layout: dict, pane_id: str, cols: int, rows: int) -> tuple[int, int]:
    area = layout.get("area") or {}
    rect = None
    for pane in layout.get("panes") or []:
        if pane.get("pane_id") == pane_id:
            rect = pane.get("rect")
            break
    if not rect or not area:
        return 0, 0

    # An overlay sized to the pane itself (modulo its border) needs no padding;
    # one sized to the whole tab area does.
    if cols - rect.get("width", 0) <= 2 and rows - rect.get("height", 0) <= 2:
        return 0, 0

    dx = max(0, rect.get("x", 0) - area.get("x", 0))
    dy = max(0, rect.get("y", 0) - area.get("y", 0))
    return dx, dy


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", required=True)
    parser.add_argument("--pane", default="")
    parser.add_argument("--cols", type=int, required=True)
    parser.add_argument("--rows", type=int, required=True)
    parser.add_argument("--align", default="auto", choices=["auto", "off"])
    args = parser.parse_args()

    with open(args.capture, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().split("\n")

    dx = dy = 0
    if args.align == "auto" and args.pane:
        raw = sys.stdin.read().strip()
        if raw:
            try:
                layout = json.loads(raw)["result"]["layout"]
            except (ValueError, KeyError, TypeError):
                layout = None
            if layout:
                dx, dy = offsets(layout, args.pane, args.cols, args.rows)

    pad = " " * dx
    padded = [""] * dy + [pad + line if line else line for line in lines]
    for line in padded[: args.rows]:
        sys.stdout.write(clip(line, args.cols) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
