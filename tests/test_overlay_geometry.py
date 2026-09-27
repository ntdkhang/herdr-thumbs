"""The overlay must wait for its real PTY size before clipping the capture."""

import fcntl
import json
import os
import pathlib
import pty
import struct
import tempfile
import termios
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class OverlayGeometryTests(unittest.TestCase):
    def test_picker_receives_bottom_row_after_initial_80x24_size(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            capture = root / "capture.txt"
            capture.write_text("\n".join([""] * 34 + ["https://example.org/bottom"]))
            layout = root / "layout.json"
            layout.write_text(
                json.dumps(
                    {
                        "result": {
                            "layout": {
                                "area": {"x": 0, "y": 0, "width": 120, "height": 40},
                                "panes": [
                                    {
                                        "pane_id": "w1:p1",
                                        "rect": {"x": 0, "y": 0, "width": 120, "height": 40},
                                    }
                                ],
                            }
                        }
                    }
                )
            )
            picker = root / "thumbs"
            picker.write_text('#!/bin/sh\ncat > "$PREPARED_FILE"\n')
            picker.chmod(0o755)
            prepared = root / "picker-input.txt"
            env = os.environ.copy()
            env.update(
                {
                    "TERM": "xterm-256color",
                    "HERDR_PLUGIN_ROOT": str(ROOT),
                    "HERDR_PLUGIN_CONFIG_DIR": str(root),
                    "HERDR_PLUGIN_STATE_DIR": str(root),
                    "PREPARED_FILE": str(prepared),
                    "THUMBS_BIN": str(picker),
                    "THUMBS_CAPTURE": str(capture),
                    "THUMBS_LAYOUT": str(layout),
                    "THUMBS_TARGET_PANE": "w1:p1",
                }
            )
            pid, fd = pty.fork()
            if pid == 0:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
                os.execve("/bin/bash", ["bash", str(ROOT / "scripts/overlay.sh")], env)

            try:
                time.sleep(0.08)
                fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    done, status = os.waitpid(pid, os.WNOHANG)
                    if done:
                        self.assertEqual(os.waitstatus_to_exitcode(status), 0)
                        break
                    time.sleep(0.01)
                else:
                    os.kill(pid, 9)
                    os.waitpid(pid, 0)
                    self.fail("overlay did not exit")
                self.assertIn("https://example.org/bottom", prepared.read_text())
            finally:
                os.close(fd)
