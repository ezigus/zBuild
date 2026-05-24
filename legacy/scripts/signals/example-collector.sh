#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Example External Signal Collector for Shipwright Decision Engine        ║
# ║  Place custom collectors in scripts/signals/ — they're auto-discovered  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Output: one JSON candidate per line (JSONL).
# Required fields: id, signal, category, title, description, risk_score,
#                  confidence, dedup_key
# Optional fields: evidence (object)
#
# The decision engine collects output from all scripts/signals/*.sh files,
# validates each line as JSON, and includes valid candidates in the scoring
# pipeline.
#
# Categories (determines autonomy tier):
#   auto:    deps_patch, deps_minor, security_patch, test_coverage,
#            doc_sync, dead_code
#   propose: refactor_hotspot, architecture_drift, performance_regression,
#            deps_major, security_critical, recurring_failure, dora_regression
#   draft:   new_feature, breaking_change, business_logic, api_change,
#            data_model_change
#
# Example: detect a custom condition and emit a candidate
#

set -euo pipefail

# Example: check if a TODO count exceeds a threshold
TODO_COUNT=$(grep -r "TODO" --include="*.ts" --include="*.js" --include="*.sh" . 2>/dev/null | wc -l | tr -d ' ' || echo "0")

if [[ "${TODO_COUNT:-0}" -gt 50 ]]; then
    cat <<EOF
{"id":"custom-todo-cleanup","signal":"custom","category":"dead_code","title":"Clean up ${TODO_COUNT} TODOs","description":"Codebase has ${TODO_COUNT} TODO comments — consider a cleanup sprint","evidence":{"todo_count":${TODO_COUNT}},"risk_score":15,"confidence":"0.70","dedup_key":"custom:todo:cleanup"}
EOF
fi
