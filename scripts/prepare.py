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
import re
import sys
import unicodedata
from pathlib import Path

URL = re.compile(r"(?:https?://|git@|git://|ssh://|ftp://|file:///)[^\s]+")


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


def pane_width(layout: dict, pane_id: str) -> int:
    for pane in layout.get("panes") or []:
        if pane.get("pane_id") == pane_id:
            return pane.get("rect", {}).get("width", 0)
    return 0


def wrapped_urls(lines: list[str], unwrapped: str, width: int) -> dict[str, str]:
    """Map visible URL prefixes to complete URLs from Herdr's logical lines.

    Only restore URLs at the right edge that continue on the next visible row.
    An ambiguous prefix is left alone rather than opening a different link.
    """
    if not width or not unwrapped:
        return {}
    full_urls = set(URL.findall(unwrapped))
    matches: dict[str, set[str]] = {}
    for current, following in zip(lines, lines[1:]):
        if not following or following[0].isspace():
            continue
        for match in URL.finditer(current):
            prefix = match.group()
            if display_width(current[: match.end()]) != width:
                continue
            candidates = {
                full
                for full in full_urls
                if full.startswith(prefix)
                and len(full) > len(prefix)
                and (
                    full[len(prefix) :].startswith(following)
                    or following.startswith(full[len(prefix) :])
                )
            }
            matches.setdefault(prefix, set()).update(candidates)
    return {prefix: next(iter(values)) for prefix, values in matches.items() if len(values) == 1}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", required=True)
    parser.add_argument("--pane", default="")
    parser.add_argument("--cols", type=int, required=True)
    parser.add_argument("--rows", type=int, required=True)
    parser.add_argument("--align", default="auto", choices=["auto", "off"])
    parser.add_argument("--unwrapped")
    parser.add_argument("--url-map")
    args = parser.parse_args()

    with open(args.capture, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().split("\n")

    layout = {}
    dx = dy = 0
    if args.pane:
        raw = sys.stdin.read().strip()
        if raw:
            try:
                layout = json.loads(raw)["result"]["layout"]
            except (ValueError, KeyError, TypeError):
                layout = {}
            if layout and args.align == "auto":
                dx, dy = offsets(layout, args.pane, args.cols, args.rows)

    if args.url_map:
        unwrapped = (
            Path(args.unwrapped).read_text(encoding="utf-8", errors="replace")
            if args.unwrapped
            else ""
        )
        urls = wrapped_urls(
            lines[: max(0, args.rows - dy)], unwrapped, pane_width(layout, args.pane)
        )
        if urls:
            with open(args.url_map, "w", encoding="utf-8") as handle:
                json.dump(urls, handle)

    pad = " " * dx
    padded = [""] * dy + [pad + line if line else line for line in lines]
    for line in padded[: args.rows]:
        sys.stdout.write(clip(line, args.cols) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
