# herdr-thumbs

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

Then bind the actions in `~/.config/herdr/config.toml` (plugin manifests cannot
register keys themselves):

```toml
[[keys.command]]
key = "prefix+space"
type = "plugin_action"
command = "sd2k.thumbs.pick"
description = "pick text (copy)"

[[keys.command]]
key = "prefix+alt+space"
type = "plugin_action"
command = "sd2k.thumbs.pick-multi"
description = "pick several"

[[keys.command]]
key = "prefix+o"
type = "plugin_action"
command = "sd2k.thumbs.pick-open"
description = "pick text (open)"
```

Reload with `herdr server reload-config`.

For local development, clone the repo and link it instead:

```sh
sh scripts/build.sh          # plugin link does not run build commands
herdr plugin link .
```

## Using it

| Key | What it does |
| --- | --- |
| a hint letter | copies that match and closes |
| an uppercase hint letter | copies it *and* types it into the pane it came from |
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

An uppercase hint in open mode copies instead of opening, and every one of these
is configurable. `file.rs:42` line numbers come from a pattern this plugin adds
on top of the upstream set.

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

## Credits

The picker is [tmux-thumbs](https://github.com/fcsonline/tmux-thumbs) by Ferran
Basora, fetched and built at install time under its own MIT license. This
wrapper is MIT licensed too.
