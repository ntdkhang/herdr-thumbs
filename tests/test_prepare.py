"""Tests for scripts/prepare.py, the capture-to-overlay layout step."""

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
PREPARE = ROOT / "scripts" / "prepare.py"

spec = importlib.util.spec_from_file_location("prepare", PREPARE)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def layout(panes, area=None):
    return {
        "area": area or {"x": 26, "y": 1, "width": 143, "height": 48},
        "panes": panes,
    }


class DisplayWidthTests(unittest.TestCase):
    def test_ascii_is_one_cell_per_character(self):
        self.assertEqual(prepare.display_width("herdr"), 5)

    def test_wide_characters_are_two_cells(self):
        self.assertEqual(prepare.display_width("日本語"), 6)

    def test_clip_respects_cell_width_not_character_count(self):
        self.assertEqual(prepare.clip("日本語", 4), "日本")
        self.assertEqual(prepare.clip("abcdef", 3), "abc")

    def test_clip_leaves_short_lines_alone(self):
        self.assertEqual(prepare.clip("abc", 10), "abc")


class OffsetTests(unittest.TestCase):
    def test_overlay_sized_to_the_pane_needs_no_padding(self):
        # A pane filling the tab, overlay one border smaller.
        panes = [{"pane_id": "w1:p1", "rect": {"x": 26, "y": 1, "width": 143, "height": 48}}]
        self.assertEqual(prepare.offsets(layout(panes), "w1:p1", 141, 47), (0, 0))

    def test_tab_sized_overlay_pads_to_the_pane_position(self):
        # Lower half of a vertical split: the overlay covers the whole tab, so
        # the capture has to start 24 rows down to line up.
        panes = [
            {"pane_id": "w1:p1", "rect": {"x": 26, "y": 1, "width": 143, "height": 24}},
            {"pane_id": "w1:p2", "rect": {"x": 26, "y": 25, "width": 143, "height": 24}},
        ]
        self.assertEqual(prepare.offsets(layout(panes), "w1:p2", 141, 47), (0, 24))

    def test_right_hand_pane_pads_horizontally(self):
        panes = [
            {"pane_id": "w1:p1", "rect": {"x": 26, "y": 1, "width": 71, "height": 48}},
            {"pane_id": "w1:p2", "rect": {"x": 98, "y": 1, "width": 71, "height": 48}},
        ]
        self.assertEqual(prepare.offsets(layout(panes), "w1:p2", 141, 47), (72, 0))

    def test_unknown_pane_falls_back_to_no_padding(self):
        panes = [{"pane_id": "w1:p1", "rect": {"x": 26, "y": 1, "width": 143, "height": 48}}]
        self.assertEqual(prepare.offsets(layout(panes), "w1:pZ", 141, 47), (0, 0))

    def test_missing_layout_falls_back_to_no_padding(self):
        self.assertEqual(prepare.offsets({}, "w1:p1", 141, 47), (0, 0))


class EndToEndTests(unittest.TestCase):
    def run_prepare(self, capture, layout_json, cols, rows, align="auto", pane="w1:p2"):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            handle.write(capture)
            path = handle.name
        result = subprocess.run(
            [
                sys.executable,
                str(PREPARE),
                "--capture",
                path,
                "--pane",
                pane,
                "--cols",
                str(cols),
                "--rows",
                str(rows),
                "--align",
                align,
            ],
            input=layout_json,
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout

    def test_padding_and_clipping(self):
        panes = [
            {"pane_id": "w1:p1", "rect": {"x": 0, "y": 0, "width": 80, "height": 2}},
            {"pane_id": "w1:p2", "rect": {"x": 0, "y": 2, "width": 80, "height": 2}},
        ]
        body = json.dumps(
            {"result": {"layout": layout(panes, {"x": 0, "y": 0, "width": 80, "height": 4})}}
        )
        out = self.run_prepare("abcdefgh\nij\n", body, cols=4, rows=6)
        self.assertEqual(out.splitlines(), ["", "", "abcd", "ij", ""])

    def test_align_off_skips_the_padding(self):
        panes = [
            {"pane_id": "w1:p1", "rect": {"x": 0, "y": 0, "width": 80, "height": 2}},
            {"pane_id": "w1:p2", "rect": {"x": 0, "y": 2, "width": 80, "height": 2}},
        ]
        body = json.dumps(
            {"result": {"layout": layout(panes, {"x": 0, "y": 0, "width": 80, "height": 4})}}
        )
        out = self.run_prepare("abc\n", body, cols=10, rows=6, align="off")
        self.assertEqual(out.splitlines(), ["abc", ""])

    def test_row_limit_is_the_overlay_height(self):
        body = json.dumps({"result": {"layout": layout([])}})
        out = self.run_prepare("1\n2\n3\n4\n5\n", body, cols=10, rows=3)
        self.assertEqual(out.splitlines(), ["1", "2", "3"])

    def test_garbage_layout_is_tolerated(self):
        out = self.run_prepare("hello\n", "not json at all", cols=10, rows=3)
        self.assertEqual(out.splitlines(), ["hello", ""])


if __name__ == "__main__":
    unittest.main()
