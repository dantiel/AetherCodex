#!/usr/bin/env bash
#
# install-aliases.sh — install short command names for the two CLIs.
#
#   aethercodex  → acx (primary), ax, ae      (editor control)
#   aetheroracle → ao, oracle, pythia         (the oracle CLI gem)
#
# Usage:
#   ./install-aliases.sh [BIN_DIR]      # default: /usr/local/bin
#   BIN_DIR="$HOME/.local/bin" ./install-aliases.sh

set -euo pipefail

DEST="${1:-${AETHERCODEX_BIN_DIR:-/usr/local/bin}}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACX="$SRC_DIR/aethercodex"
ORACLE="$(command -v aetheroracle || true)"

[[ -x "$ACX" ]] || { echo "error: $ACX not found/executable" >&2; exit 1; }

mkdir -p "$DEST" || { echo "error: cannot create $DEST (try BIN_DIR=\$HOME/bin)" >&2; exit 1; }

for a in acx ax ae; do
  ln -sf "$ACX" "$DEST/$a" && echo "linked $DEST/$a -> $ACX"
done

if [[ -n "$ORACLE" ]]; then
  for a in ao oracle pythia; do
    ln -sf "$ORACLE" "$DEST/$a" && echo "linked $DEST/$a -> $ORACLE"
  done
else
  echo "note: aetheroracle not on PATH — skipped ao/oracle/pythia" >&2
fi

echo
echo "done — make sure '$DEST' is on your PATH."
