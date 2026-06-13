---
migrated: 2026-06-13
issue: https://github.com/zbuild/zbuild/issues/755
pr: zbuild/issue-755-a2-migrate-compound-quality-as-4-agent
---

# A2 — compound_quality → 4 CQ agent plugins

## Summary

The 1013-line `stage_compound_quality` monolith from
`legacy/scripts/lib/pipeline-intelligence.sh:1959-2972` has been split into
four independent leaf-stage agent plugins.

## Function-by-function mapping

| Legacy function | Migrated to |
|---|---|
| `stage_compound_quality` (entry point, lines 1959-2035) | `plugins/agent/cq-preflight/plugin.sh` + `cq-cycle/plugin.sh` |
| `_cq_preflight_checks` (lines 2042-2195) | `plugins/agent/cq-preflight/plugin.sh` |
| `pipeline_select_audits` (lines 429-508) | `plugins/agent/cq-audit-plan/plugin.sh` |
| `_cq_run_cycle` / cycle loop (lines 2236-2900) | `plugins/agent/cq-cycle/plugin.sh` |
| `pipeline_backtrack_to_stage` (lines 1339-1422) | `plugins/agent/cq-backtrack/plugin.sh` |
| `_extract_blocking_items` (lines 1423-1480) | `plugins/agent/cq-backtrack/plugin.sh` |
| `_write_quality_feedback` (lines 1481-1520) | `plugins/agent/cq-cycle/plugin.sh` |

## New plugin locations

- `plugins/agent/cq-preflight/` — bash-compat, coverage, untested-function checks
- `plugins/agent/cq-audit-plan/` — reads quality-score history, emits audit-plan.json
- `plugins/agent/cq-cycle/` — iterative audit loop, emits quality-feedback.md
- `plugins/agent/cq-backtrack/` — architecture-class backtrack, non-blocking

## 5-test trial checklist

- [x] T1: all 4 cq-* plugin.run.start events appear in events.jsonl
- [x] T2: cq-preflight runs before cq-audit-plan
- [x] T3: missing cq-preflight/plugin.sh causes pipeline failure with correct error
- [x] T4: cq-audit-plan runs before cq-cycle
- [x] T5: cq-backtrack runs after cq-cycle and before review

## Remaining blockers

- None. All 4 plugins are first-class leaf stages in standard.yaml.
