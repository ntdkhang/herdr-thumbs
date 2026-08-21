#!/usr/bin/env bash
# Action entrypoint: capture the pane the user is looking at, then open the
# hint overlay over it. Called as `pick.sh copy` or `pick.sh open`.
set -uo pipefail

# shellcheck source=scripts/lib.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config

mode=${1:-copy}
variant=${2:-single}

target=${HERDR_PANE_ID:-}
if [[ -z $target && -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]]; then
  target=$(json_str "$HERDR_PLUGIN_CONTEXT_JSON" focused_pane_id)
fi
if [[ -z $target ]]; then
  target=$(json_str "$("$HERDR" pane current 2>/dev/null)" pane_id)
fi
[[ -n $target ]] || die "could not work out which pane to read"

# Drop anything a previous run left behind after crashing mid-pick.
find "$STATE_DIR" -maxdepth 1 -name 'capture.*.txt' -o -maxdepth 1 -name 'layout.*.json' \
  -o -maxdepth 1 -name 'prepared.*.txt' -o -maxdepth 1 -name 'result.*.txt' 2>/dev/null |
  while IFS= read -r stale; do
    [[ -f $stale ]] && find "$stale" -mmin +60 -delete 2>/dev/null
  done

capture=$STATE_DIR/capture.$$.txt
layout=$STATE_DIR/layout.$$.json

read_args=(--source "$THUMBS_SOURCE" --format text)
[[ -n ${THUMBS_LINES:-} ]] && read_args+=(--lines "$THUMBS_LINES")

"$HERDR" pane read "$target" "${read_args[@]}" >"$capture" 2>>"$STATE_DIR/thumbs.log" ||
  die "could not read pane $target"
[[ -s $capture ]] || die "pane $target has no visible output"

"$HERDR" pane layout --pane "$target" >"$layout" 2>/dev/null || : >"$layout"

log "pick mode=$mode variant=$variant target=$target capture=$capture"

pane_env=(
  --env "THUMBS_TARGET_PANE=$target"
  --env "THUMBS_CAPTURE=$capture"
  --env "THUMBS_LAYOUT=$layout"
  --env "THUMBS_MODE=$mode"
)
[[ $variant == multi ]] && pane_env+=(--env "THUMBS_MULTI=1")

"$HERDR" plugin pane open \
  --plugin "${HERDR_PLUGIN_ID:-sd2k.thumbs}" \
  --entrypoint hints \
  --focus \
  "${pane_env[@]}" >/dev/null || die "could not open the hint overlay"
