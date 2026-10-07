# Build Checkpoint — Issue #1799 (COMPLETE)

All 43 tests pass including all 4 new SPECs (tests 10-13).

## Changes made

1. `plugins/tool/pr-open/lib/advisory-section.sh`: Added `_pr_open_render_convergence_section` (renders "> ⚠️ **<cycle_id> not converged** (<N>/<M> iterations)"), `_pr_open_render_gate_section` (renders failing gate names and reason). Modified `_pr_open_compose_body` to accept args 7 (_convergence_json) and 8 (_gate_aggregator_path) and include the new sections.

2. `plugins/tool/pr-open/plugin.sh`: After `_draft_bool` resolution, added state-aware draft forcing (reads state.status and cycle_iterations). Also added `_gate_aggregator_path` reading from ZBUILD_STAGE_INPUTS. Updated `_pr_open_compose_body` call to pass 2 new args.

3. `plugins/tool/pr-open/manifest.yaml`: Added `gate_aggregator_result` as optional input.
