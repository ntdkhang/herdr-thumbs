#!/usr/bin/env bash
# Pane entrypoint: render the capture with hints, then act on what was picked.
set -uo pipefail

# shellcheck source=scripts/lib.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config

target=${THUMBS_TARGET_PANE:-}
capture=${THUMBS_CAPTURE:-}
layout=${THUMBS_LAYOUT:-}
unwrapped=${THUMBS_UNWRAPPED:-}
mode=${THUMBS_MODE:-copy}
prepared=$STATE_DIR/prepared.$$.txt
url_map=$STATE_DIR/urls.$$.json
result=$STATE_DIR/result.$$.txt
remapped=$STATE_DIR/remapped.$$.txt

cleanup() { rm -f "$capture" "$unwrapped" "$layout" "$prepared" "$url_map" "$result" "$remapped"; }
trap cleanup EXIT

# The overlay closes the moment this script exits, so an error needs a keypress
# to stay on screen long enough to read.
bail() {
  printf '\n  herdr-thumbs: %s\n\n  Press any key to close.' "$1" >&2
  read -rsn 1 -t 30 _ || true
  exit 1
}

[[ -s ${capture:-} ]] || bail "nothing was captured from the pane"

bin=$(thumbs_bin) || bin=
[[ -n $bin ]] ||
  bail "no thumbs binary found. Run scripts/build.sh in the plugin directory, or set THUMBS_BIN in $CONFIG_DIR/config.env"

# The overlay PTY can start at 80x24 before Herdr applies the tab size. Using
# that initial size cuts off the bottom of the source screen (and its hints).
expected_rows=0 expected_cols=0
if [[ -s ${layout:-} ]] && command -v python3 >/dev/null 2>&1; then
  read -r expected_rows expected_cols <<<"$(python3 -c '
import json, sys
try:
    area = json.load(sys.stdin)["result"]["layout"]["area"]
    print(area["height"], area["width"])
except (KeyError, TypeError, ValueError):
    print(0, 0)
' <"$layout")"
fi
for ((attempt=0; attempt<20; attempt++)); do
  geometry=$(stty size </dev/tty 2>/dev/null) || geometry=
  read -r rows cols <<<"$geometry"
  [[ $rows =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] || break
  ((expected_rows == 0 || expected_cols == 0 ||
    (rows >= expected_rows - 2 && cols >= expected_cols - 2))) && break
  sleep 0.025
done
if [[ ! $rows =~ ^[0-9]+$ || ! $cols =~ ^[0-9]+$ ]]; then
  cols=$(tput cols 2>/dev/null || echo 80)
  rows=$(tput lines 2>/dev/null || echo 24)
fi
log "overlay geometry=${cols}x${rows} layout=${expected_cols}x${expected_rows} source=$target"

if command -v python3 >/dev/null 2>&1; then
  python3 "$PLUGIN_ROOT/scripts/prepare.py" \
    --capture "$capture" --pane "$target" \
    --unwrapped "${unwrapped:-/dev/null}" --url-map "$url_map" \
    --cols "$cols" --rows "$rows" --align "$THUMBS_ALIGN" \
    <"${layout:-/dev/null}" >"$prepared" 2>>"$STATE_DIR/thumbs.log"
else
  # No python3: skip pane alignment and just clip the capture to the overlay.
  awk -v n="$cols" '{print substr($0, 1, n)}' "$capture" | head -n "$rows" >"$prepared"
fi
[[ -s $prepared ]] || bail "could not prepare the capture for display"

pattern_args=()
while IFS= read -r file; do pattern_args+=("$file"); done < <(pattern_files)
picker_args=()
while IFS= read -r arg; do picker_args+=("$arg"); done < <(thumbs_args "${pattern_args[@]}")
: >"$result"
"$bin" --format '%U:%H' --target "$result" "${picker_args[@]}" <"$prepared"

# thumbs exits non-zero when the user pressed Escape without picking anything.
[[ -s $result ]] || exit 0

matches=()
upcase=0
while IFS= read -r line || [[ -n $line ]]; do
  [[ -z $line ]] && continue
  [[ ${line%%:*} == true ]] && upcase=1
  matches+=("${line#*:}")
done <"$result"
((${#matches[@]})) || exit 0

if [[ -s $url_map ]]; then
  # The picker returns the visible prefix; use the matching complete URL for
  # copy, paste and open alike. Unknown and ambiguous prefixes stay unchanged.
  printf '%s\n' "${matches[@]}" | python3 "$PLUGIN_ROOT/scripts/restore_urls.py" "$url_map" >"$remapped"
  matches=()
  while IFS= read -r match || [[ -n $match ]]; do matches+=("$match"); done <"$remapped"
  rm -f "$remapped"
fi

joined=$(printf '%s ' "${matches[@]}")
joined=${joined% }
log "picked mode=$mode upcase=$upcase count=${#matches[@]}"

pane_cwd() {
  local json cwd
  json=$("$HERDR" pane get "$target" 2>/dev/null)
  cwd=$(json_str "$json" foreground_cwd)
  [[ -z $cwd ]] && cwd=$(json_str "$json" cwd)
  printf '%s' "${cwd:-$HOME}"
}

# Run a command detached, so it survives this pane closing a moment later.
detach() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 &
  else
    nohup "$@" >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
}

match_kind() {
  local m=$1
  if [[ $m =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
    printf 'url'
  elif [[ $m =~ ^[0-9a-f]{7,40}$ ]]; then
    printf 'sha'
  elif [[ $m == */* || $m == \~* || $m == .* ]]; then
    printf 'path'
  else
    printf 'other'
  fi
}

# Split "src/main.rs:42:7" into a path and a line number, resolved against the
# captured pane's working directory. Fails when nothing on disk matches.
resolve_path() {
  local raw=$1 cwd=$2 line=
  local file=$raw
  while [[ $file =~ ^(.+):([0-9]+)$ ]]; do
    line=${BASH_REMATCH[2]}
    file=${BASH_REMATCH[1]}
  done
  file=${file%%:*[!0-9]*}
  [[ $file == \~* ]] && file=${file/#\~/$HOME}
  [[ $file != /* ]] && file=$cwd/$file
  [[ -e $file ]] || return 1
  printf '%s\t%s' "$file" "$line"
}

run_template() {
  local template=$1 match=$2 cwd=$3 quoted
  quoted=$(printf '%q' "$match")
  detach bash -c "cd $(printf '%q' "$cwd") && ${template//\{\}/$quoted}"
}

open_in_split() {
  local cwd=$1 command=$2 json pane
  json=$("$HERDR" pane split "$target" --direction right --cwd "$cwd" --no-focus 2>/dev/null)
  pane=$(json_str "$json" pane_id)
  [[ -n $pane ]] || return 1
  "$HERDR" pane run "$pane" "$command" >/dev/null 2>&1 || return 1
  # Focus has to land after the overlay closes and restores the old focus.
  detach bash -c "sleep 0.3; $(printf '%q' "$HERDR") pane focus --direction right --pane $(printf '%q' "$target") >/dev/null 2>&1"
}

open_match() {
  local match=$1 cwd=$2 kind
  kind=$(match_kind "$match")

  case $kind in
    url)
      if [[ -n $THUMBS_OPEN_URL ]]; then
        run_template "$THUMBS_OPEN_URL" "$match" "$cwd"
      elif [[ ${OSTYPE:-} == darwin* ]] && command -v open >/dev/null 2>&1; then
        detach open -a 'Google Chrome' "$match"
      elif [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] && command -v xdg-open >/dev/null 2>&1; then
        detach xdg-open "$match"
      else
        return 1
      fi
      ;;
    path)
      local resolved file line
      resolved=$(resolve_path "$match" "$cwd") || return 1
      file=${resolved%%$'\t'*}
      line=${resolved#*$'\t'}
      if [[ -n $THUMBS_OPEN_PATH ]]; then
        # Keep the line number for custom openers such as open-in-nvim.
        [[ -n $line ]] && file="$file:$line"
        run_template "$THUMBS_OPEN_PATH" "$file" "$cwd"
      else
        local editor=${THUMBS_EDITOR:-${VISUAL:-${EDITOR:-vi}}} command
        command="$editor $(printf '%q' "$file")"
        [[ -n $line ]] && command="$editor +$line $(printf '%q' "$file")"
        open_in_split "$cwd" "$command"
      fi
      ;;
    sha)
      if [[ -n $THUMBS_OPEN_SHA ]]; then
        run_template "$THUMBS_OPEN_SHA" "$match" "$cwd"
      else
        open_in_split "$cwd" "git show $(printf '%q' "$match")"
      fi
      ;;
    other)
      if [[ -n $THUMBS_OPEN_OTHER && $THUMBS_OPEN_OTHER != copy ]]; then
        run_template "$THUMBS_OPEN_OTHER" "$match" "$cwd"
      else
        return 1
      fi
      ;;
  esac
}

# An uppercase hint overrides the action it was invoked from.
act=$mode
if ((upcase)); then
  case $THUMBS_UPCASE in
    open) act="open" ;;
    copy) act="copy" ;;
    swap) [[ $mode == open ]] && act="copy" || act="open" ;;
    *) act="paste" ;;
  esac
fi

copy_and_notify() {
  if copy_to_clipboard "$joined"; then
    notify "Copied" "$(short "$joined")"
  else
    bail "could not copy the selection — see $STATE_DIR/thumbs.log"
  fi
}

case $act in
  paste)
    copied=0
    copy_to_clipboard "$joined" && copied=1
    if [[ -n $target ]] && "$HERDR" pane send-text "$target" "$joined" >/dev/null 2>&1; then
      notify "Pasted" "$(short "$joined")"
    elif ((copied)); then
      notify "Copied" "$(short "$joined")"
    else
      bail "could not paste or copy the selection — see $STATE_DIR/thumbs.log"
    fi
    ;;
  open)
    cwd=$(pane_cwd)
    opened=0
    for match in "${matches[@]}"; do
      if open_match "$match" "$cwd"; then
        opened=$((opened + 1))
      else
        log "no open action for match: $match"
      fi
    done
    if ((opened == 0)); then
      copy_and_notify
    elif ((opened == 1)); then
      notify "Opened" "$(short "$joined")"
    else
      notify "Opened $opened matches" "$(short "$joined")"
    fi
    ;;
  *)
    copy_and_notify
    ;;
esac
