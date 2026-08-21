#!/usr/bin/env bash
# Pane entrypoint: render the capture with hints, then act on what was picked.
set -uo pipefail

# shellcheck source=scripts/lib.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config

target=${THUMBS_TARGET_PANE:-}
capture=${THUMBS_CAPTURE:-}
layout=${THUMBS_LAYOUT:-}
mode=${THUMBS_MODE:-copy}
prepared=$STATE_DIR/prepared.$$.txt
result=$STATE_DIR/result.$$.txt

cleanup() { rm -f "$capture" "$layout" "$prepared" "$result"; }
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

cols=$(tput cols 2>/dev/null || echo 80)
rows=$(tput lines 2>/dev/null || echo 24)

if command -v python3 >/dev/null 2>&1; then
  python3 "$PLUGIN_ROOT/scripts/prepare.py" \
    --capture "$capture" --pane "$target" \
    --cols "$cols" --rows "$rows" --align "$THUMBS_ALIGN" \
    <"${layout:-/dev/null}" >"$prepared" 2>>"$STATE_DIR/thumbs.log"
else
  # No python3: skip pane alignment and just clip the capture to the overlay.
  awk -v n="$cols" '{print substr($0, 1, n)}' "$capture" | head -n "$rows" >"$prepared"
fi
[[ -s $prepared ]] || bail "could not prepare the capture for display"

mapfile -t pattern_args < <(pattern_files)
mapfile -t picker_args < <(thumbs_args "${pattern_args[@]}")
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
        detach open "$match"
      elif command -v xdg-open >/dev/null 2>&1; then
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
