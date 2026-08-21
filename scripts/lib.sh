# shellcheck shell=bash
# Shared helpers for the herdr-thumbs plugin scripts.

HERDR=${HERDR_BIN_PATH:-herdr}
PLUGIN_ROOT=${HERDR_PLUGIN_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
CONFIG_DIR=${HERDR_PLUGIN_CONFIG_DIR:-$PLUGIN_ROOT/config}
STATE_DIR=${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-thumbs}
mkdir -p "$STATE_DIR"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$STATE_DIR/thumbs.log"
}

die() {
  log "error: $*"
  printf 'herdr-thumbs: %s\n' "$*" >&2
  exit 1
}

# Pull a flat "key":"value" string out of a herdr JSON response without
# depending on jq. Only used for scalar fields that cannot contain quotes.
json_str() {
  local json=$1 key=$2
  printf '%s' "$json" |
    grep -o "[{,]\"$key\":\"[^\"]*\"" |
    head -n 1 |
    sed "s/^[{,]\"$key\":\"//; s/\"$//"
}

load_config() {
  if [[ -f $CONFIG_DIR/config.env ]]; then
    set -a
    # shellcheck disable=SC1091  # user-owned config, path known at runtime only
    . "$CONFIG_DIR/config.env"
    set +a
  fi

  # Picker appearance and behaviour (mirrors tmux-thumbs options).
  : "${THUMBS_ALPHABET:=qwerty}"
  : "${THUMBS_POSITION:=left}"
  # Off by default, like tmux-thumbs: a single hint picks and closes.
  # Space during a pick turns multi-selection on mid-flight; a second Space
  # finalises it. THUMBS_MULTI=1 starts in multi-selection mode instead.
  : "${THUMBS_MULTI:=0}"
  : "${THUMBS_REVERSE:=1}"
  : "${THUMBS_UNIQUE:=1}"
  : "${THUMBS_CONTRAST:=0}"
  : "${THUMBS_FG_COLOR:=green}"
  : "${THUMBS_BG_COLOR:=black}"
  : "${THUMBS_HINT_FG_COLOR:=yellow}"
  : "${THUMBS_HINT_BG_COLOR:=black}"
  : "${THUMBS_SELECT_FG_COLOR:=blue}"
  : "${THUMBS_SELECT_BG_COLOR:=black}"
  : "${THUMBS_MULTI_FG_COLOR:=yellow}"
  : "${THUMBS_MULTI_BG_COLOR:=black}"

  # Plugin behaviour.
  : "${THUMBS_ALIGN:=auto}"
  : "${THUMBS_CLIPBOARD:=auto}"
  : "${THUMBS_NOTIFY:=1}"
  : "${THUMBS_PASTE_ON_UPCASE:=1}"
  : "${THUMBS_SOURCE:=visible}"

  # Extra match patterns: the shipped defaults plus the user's own.
  : "${THUMBS_DEFAULT_PATTERNS:=1}"

  # Per-kind actions for the "open" action. {} is replaced with the match.
  : "${THUMBS_OPEN_URL:=}"
  : "${THUMBS_OPEN_PATH:=}"
  : "${THUMBS_OPEN_SHA:=}"
  : "${THUMBS_OPEN_OTHER:=copy}"
}

on() { [[ ${1:-0} == 1 || ${1:-0} == true || ${1:-0} == yes ]]; }

thumbs_bin() {
  if [[ -n ${THUMBS_BIN:-} && -x ${THUMBS_BIN} ]]; then
    printf '%s\n' "$THUMBS_BIN"
    return 0
  fi
  if [[ -x $PLUGIN_ROOT/vendor/bin/thumbs ]]; then
    printf '%s\n' "$PLUGIN_ROOT/vendor/bin/thumbs"
    return 0
  fi
  command -v thumbs 2>/dev/null
}

# Build the thumbs argv from config plus the pattern files passed in.
thumbs_args() {
  local -a args=(
    --alphabet "$THUMBS_ALPHABET"
    --position "$THUMBS_POSITION"
    --fg-color "$THUMBS_FG_COLOR"
    --bg-color "$THUMBS_BG_COLOR"
    --hint-fg-color "$THUMBS_HINT_FG_COLOR"
    --hint-bg-color "$THUMBS_HINT_BG_COLOR"
    --select-fg-color "$THUMBS_SELECT_FG_COLOR"
    --select-bg-color "$THUMBS_SELECT_BG_COLOR"
    --multi-fg-color "$THUMBS_MULTI_FG_COLOR"
    --multi-bg-color "$THUMBS_MULTI_BG_COLOR"
  )
  on "$THUMBS_MULTI" && args+=(--multi)
  on "$THUMBS_REVERSE" && args+=(--reverse)
  on "$THUMBS_UNIQUE" && args+=(--unique)
  on "$THUMBS_CONTRAST" && args+=(--contrast)

  local file line
  for file in "$@"; do
    [[ -f $file ]] || continue
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -z ${line// /} || $line == \#* ]] && continue
      args+=(--regexp "$line")
    done <"$file"
  done

  printf '%s\n' "${args[@]}"
}

osc52_copy() {
  local b64
  b64=$(printf '%s' "$1" | base64 | tr -d '\r\n')
  printf '\033]52;c;%s\a' "$b64" >/dev/tty 2>/dev/null || return 1
  # Give herdr a moment to read the sequence off the pty before we exit.
  sleep 0.05
}

copy_to_clipboard() {
  local text=$1

  case $THUMBS_CLIPBOARD in
    none)
      return 1
      ;;
    osc52)
      osc52_copy "$text"
      return
      ;;
    auto) ;;
    *)
      if command -v "$THUMBS_CLIPBOARD" >/dev/null 2>&1; then
        printf '%s' "$text" | "$THUMBS_CLIPBOARD" && return 0
      fi
      log "configured clipboard command '$THUMBS_CLIPBOARD' failed, falling back to OSC 52"
      osc52_copy "$text"
      return
      ;;
  esac

  # auto: prefer a native clipboard when this machine actually has one,
  # otherwise hand the text to the outer terminal over OSC 52.
  if [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$text" | wl-copy && return 0
  fi
  if [[ ${OSTYPE:-} == darwin* ]] && command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$text" | pbcopy && return 0
  fi
  if [[ -n ${DISPLAY:-} ]]; then
    if command -v xclip >/dev/null 2>&1; then
      printf '%s' "$text" | xclip -selection clipboard && return 0
    fi
    if command -v xsel >/dev/null 2>&1; then
      printf '%s' "$text" | xsel --clipboard --input && return 0
    fi
  fi
  osc52_copy "$text"
}

notify() {
  on "$THUMBS_NOTIFY" || return 0
  local title=$1 body=${2:-}
  if [[ -n $body ]]; then
    "$HERDR" notification show "$title" --body "$body" >/dev/null 2>&1 || true
  else
    "$HERDR" notification show "$title" >/dev/null 2>&1 || true
  fi
}

# Trim a match down to something readable inside a toast.
short() {
  local text=$1 limit=${2:-60}
  text=${text//$'\n'/ }
  if ((${#text} > limit)); then
    printf '%s…' "${text:0:limit}"
  else
    printf '%s' "$text"
  fi
}

# The pattern files to feed to thumbs, in priority order.
pattern_files() {
  on "$THUMBS_DEFAULT_PATTERNS" && printf '%s\n' "$PLUGIN_ROOT/config/patterns.default.txt"
  printf '%s\n' "$CONFIG_DIR/patterns.txt"
}
