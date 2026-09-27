"""Check the path and source pane sent to a custom path opener."""

import os
import pathlib
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class OpenPathTests(unittest.TestCase):
    def test_custom_opener_gets_line_number_and_source_pane(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "src" / "demo.py"
            source.parent.mkdir()
            source.touch()
            capture = root / "capture.txt"
            capture.write_text("src/demo.py:42\n")
            layout = root / "layout.json"
            layout.write_text("{}")
            result = root / "opened.txt"

            herdr = root / "herdr"
            herdr.write_text('#!/bin/sh\nprintf \'{"foreground_cwd":"%s"}\\n\' "$SOURCE_DIR"\n')
            herdr.chmod(0o755)
            picker = root / "thumbs"
            picker.write_text(
                "#!/bin/sh\n"
                'while [ "$1" != --target ]; do shift; done\n'
                "printf 'false:src/demo.py:42\\n' > \"$2\"\n"
            )
            picker.chmod(0o755)
            opener = root / "opener"
            opener.write_text(
                '#!/bin/sh\nprintf \'%s\\n%s\\n\' "$1" "$THUMBS_TARGET_PANE" > "$RESULT_FILE"\n'
            )
            opener.chmod(0o755)

            environment = os.environ.copy()
            environment.update(
                {
                    "HERDR_BIN_PATH": str(herdr),
                    "HERDR_PLUGIN_ROOT": str(ROOT),
                    "HERDR_PLUGIN_CONFIG_DIR": str(root),
                    "HERDR_PLUGIN_STATE_DIR": str(root),
                    "RESULT_FILE": str(result),
                    "SOURCE_DIR": str(root),
                    "TERM": "xterm-256color",
                    "THUMBS_BIN": str(picker),
                    "THUMBS_CAPTURE": str(capture),
                    "THUMBS_LAYOUT": str(layout),
                    "THUMBS_MODE": "open",
                    "THUMBS_OPEN_PATH": f"{opener} {{}}",
                    "THUMBS_TARGET_PANE": "w1:p1",
                }
            )
            process = subprocess.run(
                ["bash", str(ROOT / "scripts" / "overlay.sh")],
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(process.returncode, 0, process.stderr)
            deadline = time.monotonic() + 2
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(result.read_text().splitlines(), [f"{source}:42", "w1:p1"])


if __name__ == "__main__":
    unittest.main()
