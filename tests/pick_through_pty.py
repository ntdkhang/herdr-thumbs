#!/usr/bin/env python3
"""Smoke test the built picker by driving it through a real pty.

thumbs reads its keys from /dev/tty, so this is the only way to exercise a pick
without a terminal: fork a pty, feed it a hint, and check what it wrote.
"""

from __future__ import annotations

import os
import pathlib
import pty
import select
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
THUMBS = ROOT / "vendor" / "bin" / "thumbs"
CAPTURE = "see https://herdr.dev/docs/plugins/ for details\n"
EXPECTED = "https://herdr.dev/docs/plugins/"


def main() -> int:
    if not THUMBS.is_file():
        print(f"no picker at {THUMBS}; run scripts/build.sh first", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        capture = pathlib.Path(tmp, "capture.txt")
        capture.write_text(CAPTURE, encoding="utf-8")
        target = pathlib.Path(tmp, "result.txt")

        pid, fd = pty.fork()
        if pid == 0:
            os.environ["TERM"] = "xterm-256color"
            with capture.open("rb") as handle:
                os.dup2(handle.fileno(), 0)
            os.execv(
                str(THUMBS),
                [str(THUMBS), "--target", str(target), "--format", "%U:%H", "--alphabet", "qwerty"],
            )

        # Let it paint, then type the only hint there is.
        deadline = time.monotonic() + 20
        typed = False
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if ready:
                try:
                    if not os.read(fd, 65536):
                        break
                except OSError:
                    break
            if not typed:
                os.write(fd, b"a")
                typed = True
            if os.waitpid(pid, os.WNOHANG)[0]:
                break

        os.close(fd)
        picked = target.read_text(encoding="utf-8") if target.is_file() else ""

    print(f"picked: {picked!r}")
    if picked.strip() != f"false:{EXPECTED}":
        print(f"expected 'false:{EXPECTED}'", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
