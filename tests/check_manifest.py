#!/usr/bin/env python3
"""Validate herdr-plugin.toml against the rules Herdr enforces at link time.

Catches the mistakes that only show up when someone runs `herdr plugin install`:
a renamed script, a duplicate action id, a dot in a local id, an entrypoint that
points at a file that is not in the repo.
"""

from __future__ import annotations

import pathlib
import re
import sys

import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "herdr-plugin.toml"

PLUGIN_ID = re.compile(r"^[A-Za-z0-9._:-]+$")
LOCAL_ID = re.compile(r"^[A-Za-z0-9_:-]+$")  # no dots in action/pane/handler ids
PLACEMENTS = {"overlay", "popup", "split", "tab", "zoomed"}
PLATFORMS = {"linux", "macos", "windows"}
INTERPRETERS = {"sh", "bash", "python3", "node", "herdr"}

problems: list[str] = []


def fail(message: str) -> None:
    problems.append(message)


def check_command(where: str, command: object) -> None:
    if not isinstance(command, list) or not command or not all(isinstance(c, str) for c in command):
        fail(f"{where}: command must be a non-empty array of strings")
        return
    program = command[0]
    if program not in INTERPRETERS:
        fail(
            f"{where}: unexpected program {program!r}; add it to INTERPRETERS if that is deliberate"
        )
    # Any argument that looks like a repo-relative script has to exist.
    for arg in command[1:]:
        if arg.startswith("-") or "/" not in arg:
            continue
        if arg.startswith("/") or arg.startswith("$"):
            continue
        if not (ROOT / arg).is_file():
            fail(f"{where}: command references {arg}, which is not in the repo")


def check_ids(where: str, entries: list[dict]) -> None:
    seen: set[str] = set()
    for entry in entries:
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not LOCAL_ID.fullmatch(entry_id):
            fail(
                f"{where}: id {entry_id!r} must be letters, digits, colon,"
                " underscore or hyphen (no dots)"
            )
            continue
        if entry_id in seen:
            fail(f"{where}: duplicate id {entry_id!r}")
        seen.add(entry_id)


def main() -> int:
    if not MANIFEST.is_file():
        print("herdr-plugin.toml is missing", file=sys.stderr)
        return 1

    with MANIFEST.open("rb") as handle:
        manifest = tomllib.load(handle)

    for key in ("id", "name", "version", "min_herdr_version"):
        if not isinstance(manifest.get(key), str) or not manifest[key]:
            fail(f"top level: {key} is required")

    plugin_id = manifest.get("id", "")
    if plugin_id and not PLUGIN_ID.fullmatch(plugin_id):
        fail(f"top level: id {plugin_id!r} has characters Herdr does not allow")

    platforms = manifest.get("platforms")
    if not isinstance(platforms, list) or not platforms:
        fail("top level: platforms should list where the plugin runs")
    else:
        for platform in platforms:
            if platform not in PLATFORMS:
                fail(f"top level: unknown platform {platform!r}")

    if "keys" in manifest:
        fail(
            "keys: Herdr ignores keybindings in the manifest; document them for config.toml instead"
        )

    for index, build in enumerate(manifest.get("build", [])):
        check_command(f"build[{index}]", build.get("command"))

    for index, startup in enumerate(manifest.get("startup", [])):
        check_command(f"startup[{index}]", startup.get("command"))

    actions = manifest.get("actions", [])
    check_ids("actions", actions)
    for action in actions:
        where = f"action {action.get('id')!r}"
        if not action.get("title"):
            fail(f"{where}: title is required")
        check_command(where, action.get("command"))

    panes = manifest.get("panes", [])
    check_ids("panes", panes)
    for pane in panes:
        where = f"pane {pane.get('id')!r}"
        check_command(where, pane.get("command"))
        placement = pane.get("placement")
        if placement is not None and placement not in PLACEMENTS:
            fail(f"{where}: placement {placement!r} is not one of {sorted(PLACEMENTS)}")

    handlers = manifest.get("link_handlers", [])
    check_ids("link_handlers", handlers)
    action_ids = {action.get("id") for action in actions}
    for handler in handlers:
        where = f"link handler {handler.get('id')!r}"
        if handler.get("action") not in action_ids:
            fail(f"{where}: action {handler.get('action')!r} is not declared by this plugin")

    # Every documented THUMBS_* option should appear in the example config, so
    # the example stays the reference the README claims it is.
    example = (ROOT / "config" / "config.env.example").read_text(encoding="utf-8")
    lib = (ROOT / "scripts" / "lib.sh").read_text(encoding="utf-8")
    documented = set(re.findall(r"^# (THUMBS_[A-Z_]+)=", example, re.MULTILINE))
    defaulted = set(re.findall(r'^  : "\$\{(THUMBS_[A-Z_]+):=', lib, re.MULTILINE))
    for option in sorted(defaulted - documented):
        fail(f"config.env.example: {option} has a default in lib.sh but is not documented")

    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"{MANIFEST.name} ok: {len(actions)} actions, {len(panes)} panes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
