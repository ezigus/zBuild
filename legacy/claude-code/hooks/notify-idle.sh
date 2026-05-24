#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# notify-idle.sh — Desktop notification when Claude needs your attention
# ═══════════════════════════════════════════════════════════════════════
#
# Works on macOS (osascript) and Linux (notify-send).
#
# Install:
#   1. Copy this file to ~/.claude/hooks/notify-idle.sh
#   2. chmod +x ~/.claude/hooks/notify-idle.sh
#   3. Add to ~/.claude/settings.json:
#      "hooks": {
#        "Notification": [
#          {
#            "hooks": [
#              {
#                "type": "command",
#                "command": "~/.claude/hooks/notify-idle.sh",
#                "async": true
#              }
#            ]
#          }
#        ]
#      }
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

if [[ "$(uname)" == "Darwin" ]]; then
  osascript -e 'display notification "An agent needs your attention" with title "Shipwright" sound name "Ping"'
elif command -v notify-send &>/dev/null; then
  notify-send "Shipwright" "An agent needs your attention" --urgency=normal
fi

exit 0
