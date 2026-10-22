#!/usr/bin/env bash
#
# install-aliases.sh — install short command names for the two CLIs.
#
#   aethercodex  → acx (primary), ax, ac      (editor control)
#   aetheroracle → installed by the gem itself on `gem install`:
#                  aetheroracle, aether, oracle, oracleaether, ae, aero, orae
#
# Usage:
#   ./install-aliases.sh [BIN_DIR]      # default: /usr/local/bin
#   BIN_DIR="$HOME/.local/bin" ./install-aliases.sh

set -euo pipefail

DEST="${1:-${AETHERCODEX_BIN_DIR:-/usr/local/bin}}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACX="$SRC_DIR/aethercodex"

[[ -x "$ACX" ]] || { echo "error: $ACX not found/executable" >&2; exit 1; }

mkdir -p "$DEST" || { echo "error: cannot create $DEST (try BIN_DIR=\\$HOME/bin)" >&2; exit 1; }

for a in acx ax ac; do
  ln -sf "$ACX" "$DEST/$a" && echo "linked $DEST/$a -> $ACX"
done

echo
echo "note: the aetheroracle gem installs its own commands on \`gem install\` —"
echo "      aetheroracle, aether, oracle, oracleaether, ae, aero, orae"
echo
echo "done — make sure '$DEST' is on your PATH."