#!/usr/bin/env bash
# ÆtherLimen installer — the liminal background service.
#
# The service keeps the Ruby brain alive across app quit: Oracle queue, ShellSession
# cwd and Mnemosyne history stay warm. This is a deliberate, hermetic act — a service
# that outlives the app must never install itself silently, so this script is the
# single explicit gateway.
#
#   install:  Scripts/install_limen.sh
#   uninstall: Scripts/install_limen.sh --uninstall
set -euo pipefail

LABEL="com.aethercodex.limen"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/com.aethercodex.limen.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_DST"
  echo "ÆtherLimen entfernt ($LABEL)."
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl enable "gui/$(id -u)/$LABEL"

echo "ÆtherLimen installiert ($LABEL) → Socket /tmp/aether-limen.sock"
echo "Log: /tmp/aether-limen.log"
