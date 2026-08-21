#!/bin/sh
# Build the upstream tmux-thumbs picker into vendor/bin/thumbs.
#
# Run automatically by `herdr plugin install`; run it by hand after
# `herdr plugin link`. Override THUMBS_REPO/THUMBS_REF to pin a different
# revision.
set -eu

THUMBS_REPO=${THUMBS_REPO:-https://github.com/fcsonline/tmux-thumbs}
THUMBS_REF=${THUMBS_REF:-0.8.0}

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if ! command -v cargo >/dev/null 2>&1; then
  echo "herdr-thumbs: cargo not found on PATH." >&2
  echo "Install Rust (https://rustup.rs) or put a 'thumbs' binary on PATH," >&2
  echo "then set THUMBS_BIN in the plugin config." >&2
  exit 1
fi

echo "herdr-thumbs: building thumbs $THUMBS_REF from $THUMBS_REPO"
cargo install \
  --git "$THUMBS_REPO" \
  --tag "$THUMBS_REF" \
  --bin thumbs \
  --root "$root/vendor" \
  --force

echo "herdr-thumbs: installed $root/vendor/bin/thumbs"
