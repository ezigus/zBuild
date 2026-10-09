#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# pre-compact-save.sh — Save important context before compaction
# ═══════════════════════════════════════════════════════════════════════
#
# Outputs text to stdout that gets injected into Claude's context after
# compaction. Helps Claude remember project state across compaction events.
#
# Install:
#   1. Copy this file to ~/.claude/hooks/pre-compact-save.sh
#   2. chmod +x ~/.claude/hooks/pre-compact-save.sh
#   3. Add to ~/.claude/settings.json:
#      "hooks": {
#        "PreCompact": [
#          {
#            "matcher": "auto",
#            "hooks": [
#              {
#                "type": "command",
#                "command": "~/.claude/hooks/pre-compact-save.sh",
#                "statusMessage": "Saving context before compaction..."
#              }
#            ]
#          }
#        ]
#      }
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)

if [[ -n "$CWD" ]] && [[ -d "$CWD" ]]; then
  cd "$CWD"
fi

# Remind Claude of project context after compaction
echo "Post-compaction context refresh:"

# Show recent git activity
if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  echo ""
  echo "Recent commits:"
  git log --oneline -5 2>/dev/null || true
  echo ""
  echo "Current branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
  echo "Changed files: $(git diff --name-only 2>/dev/null | head -10 || true)"
fi

# Show CLAUDE.md reminder if present
if [[ -f "CLAUDE.md" ]]; then
  echo ""
  echo "Project has CLAUDE.md — re-read it for project conventions."
fi

exit 0
