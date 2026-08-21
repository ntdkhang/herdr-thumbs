# herdr-thumbs

[![CI](https://github.com/sd2k/herdr-thumbs/actions/workflows/ci.yml/badge.svg)](https://github.com/sd2k/herdr-thumbs/actions/workflows/ci.yml)

[tmux-thumbs](https://github.com/fcsonline/tmux-thumbs) for
[Herdr](https://herdr.dev): press a key, every URL, path, SHA, UUID and IP in
the pane gets a one-letter hint, press that letter, and it is on your clipboard.

```
url      ehttps://herdr.dev/docs/plugins/          <- press e
path     w/home/ben/repos/personal/herdr-thumbs    <- press w
sha      f5fdab4dbe6f4a4b1c0d9e8f7a6b5c4d3e2f109   <- press f
```

The picking is done by upstream `thumbs` itself, so the hint alphabets, match
patterns and colours are the ones you already know. This plugin is the Herdr
half: capturing the pane, laying the hints over it in the right place, and
deciding what happens to what you picked.

## Install

```sh
herdr plugin install sd2k/herdr-thumbs
```

Installing builds `thumbs` from source, so you need a Rust toolchain
([rustup](https://rustup.rs)) at install time. `python3` is optional but
recommended — without it the hints still work, they just are not aligned to the
pane's position in the tab.

To work on it locally, clone the repo and link it instead — `herdr plugin link`
does not run build commands, so build the picker yourself first:

```sh
sh scripts/build.sh
herdr plugin link .
```

## Bindings

Herdr ignores keybindings declared in a plugin manifest, so the three actions
need binding yourself. Paste this into `~/.config/herdr/config.toml` and run
`herdr server reload-config`:

```toml
# Copy a match. prefix+space is tmux-thumbs' default key.
[[keys.command]]
key = "prefix+space"
type = "plugin_action"
command = "sd2k.thumbs.pick"
description = "pick text"

# Copy several matches. Space during a normal pick does this too.
[[keys.command]]
key = "prefix+alt+space"
type = "plugin_action"
command = "sd2k.thumbs.pick-multi"
description = "pick several"

# Open a match instead of copying it: editor, browser or git show.
[[keys.command]]
key = "prefix+o"
type = "plugin_action"
command = "sd2k.thumbs.pick-open"
description = "pick text (open)"
```

Every action also works from the command line, which is handy for checking your
install: `herdr plugin action invoke sd2k.thumbs.pick`.

Actions in full:

| Action | Does |
| --- | --- |
| `sd2k.thumbs.pick` | pick one match and copy it |
| `sd2k.thumbs.pick-multi` | pick several, copied space-separated |
| `sd2k.thumbs.pick-open` | pick one match and act on it |

## Using it

| Key | What it does |
| --- | --- |
| a hint letter | copies that match and closes |
| an uppercase hint letter | whatever `THUMBS_UPCASE` says — by default copies it *and* types it into the pane it came from |
| `space` | starts multi-selection; hints then toggle, `space` again finalises |
| `↑` `↓` `←` `→` | moves the cursor between matches, `enter` picks the current one |
| `backspace` | clears a partly typed hint |
| `esc` | cancels |

Multi-selected matches are copied space-separated, which is usually what you
want for a command line.

`sd2k.thumbs.pick-open` acts on the match instead of copying it:

| Match | What happens |
| --- | --- |
| URL | opens in your browser (`xdg-open` / `open`) |
| file path | opens `$EDITOR` in a split next to the pane, at the matched line |
| git SHA | runs `git show <sha>` in a split |
| anything else | falls back to copying |

Set `THUMBS_UPCASE=open` to get tmux-thumbs' `@thumbs-upcase-command` habit, where
an uppercase hint opens the match instead of pasting it. Every action above is
configurable. `file.rs:42` line numbers come from a pattern this plugin adds
on top of the upstream set.

## Coming from tmux-thumbs

Options move from `tmux.conf` to `config.env` in the plugin config directory
(`herdr plugin config-dir sd2k.thumbs`):

| tmux-thumbs | herdr-thumbs |
| --- | --- |
| `@thumbs-key space` | a `[[keys.command]]` entry, see above |
| `@thumbs-alphabet qwerty` | `THUMBS_ALPHABET=qwerty` |
| `@thumbs-position left` | `THUMBS_POSITION=left` |
| `@thumbs-reverse enabled` | `THUMBS_REVERSE=1` |
| `@thumbs-unique enabled` | `THUMBS_UNIQUE=1` |
| `@thumbs-contrast 1` | `THUMBS_CONTRAST=1` |
| `@thumbs-multi enabled` | `THUMBS_MULTI=1` |
| `@thumbs-bg-color` / `-fg-color` | `THUMBS_BG_COLOR` / `THUMBS_FG_COLOR` |
| `@thumbs-hint-bg-color` / `-hint-fg-color` | `THUMBS_HINT_BG_COLOR` / `THUMBS_HINT_FG_COLOR` |
| `@thumbs-select-bg-color` / `-select-fg-color` | `THUMBS_SELECT_BG_COLOR` / `THUMBS_SELECT_FG_COLOR` |
| `@thumbs-multi-bg-color` / `-multi-fg-color` | `THUMBS_MULTI_BG_COLOR` / `THUMBS_MULTI_FG_COLOR` |
| `@thumbs-regexp-1`, `-2`, … | one regex per line in `patterns.txt` |
| `@thumbs-command '… xclip …'` | `THUMBS_CLIPBOARD` (default `auto` already copies) |
| `@thumbs-upcase-command '… xdg-open …'` | `THUMBS_UPCASE=open` |

So a typical tmux-thumbs setup ports to:

```sh
# ~/.config/herdr/plugins/config/sd2k.thumbs/config.env
THUMBS_UPCASE=open        # @thumbs-upcase-command 'xdg-open {}'
THUMBS_REVERSE=1          # @thumbs-reverse enabled
THUMBS_CONTRAST=1         # @thumbs-contrast 2
THUMBS_FG_COLOR=black     # @thumbs-fg-color black
THUMBS_BG_COLOR=yellow    # @thumbs-bg-color yellow
THUMBS_HINT_FG_COLOR=yellow
THUMBS_HINT_BG_COLOR=black
```

`@thumbs-command` has no direct equivalent because copying is built in: pick a
clipboard with `THUMBS_CLIPBOARD`, or use the open action for anything else.

## Configuration

Both files are optional and live in the plugin config directory
(`herdr plugin config-dir sd2k.thumbs`):

- `config.env` — appearance and behaviour. Start from
  [`config/config.env.example`](config/config.env.example), which lists every
  option with its default.
- `patterns.txt` — extra match patterns, one Rust regex per line. See
  [`config/patterns.example.txt`](config/patterns.example.txt).

## How it works

1. The action reads the pane you are looking at (`herdr pane read`) and its
   geometry (`herdr pane layout`), then opens the plugin's overlay pane.
2. The overlay pads the capture so each match sits on the cell it occupied in
   the real pane, clips it to the overlay, and hands it to `thumbs` on stdin.
3. `thumbs` renders the hints and writes what you picked to a file.
4. The overlay copies, types or opens it, shows a toast, and exits — which
   closes the overlay and restores your focus and zoom.

Two things worth knowing about the Herdr side of this:

- **Clipboard.** Herdr has no clipboard API, so the copy goes through
  `wl-copy`/`pbcopy`/`xclip`/`xsel` when a display is available, and through
  OSC 52 to the outer terminal otherwise. OSC 52 works over SSH and in a bare
  tty; a terminal that refuses OSC 52 writes will silently drop it, in which
  case set `THUMBS_CLIPBOARD` to a command that works for you.
- **Overlays cover the active pane.** Herdr does not let a plugin overlay
  target another pane, so the hints always land on the pane that had focus when
  you pressed the key. That is exactly what you want here, but it does mean the
  actions are only useful from a keybinding or the command palette, not from a
  script pointed at some other pane.

## Development

```sh
sh scripts/build.sh                        # build the vendored picker
python3 -m unittest discover -s tests      # hint layout and clipping
python3 tests/check_manifest.py            # manifest and config example agree
python3 tests/pick_through_pty.py          # drive a real pick through a pty
shellcheck --severity=style scripts/*.sh
ruff check scripts tests && ruff format --diff scripts tests
```

CI runs all of that on Linux and macOS, including building `thumbs` from the
pinned tag, so a broken install path fails before anyone hits it.

## Credits

The picker is [tmux-thumbs](https://github.com/fcsonline/tmux-thumbs) by Ferran
Basora, fetched and built at install time under its own MIT license. This
wrapper is MIT licensed too.
