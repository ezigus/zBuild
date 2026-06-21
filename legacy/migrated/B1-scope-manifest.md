# Migration Tombstone: B1-scope-manifest

**Migration date:** 2026-06-21
**Migrated under:** #754 ([A1] design stage → kind:agent plugin)
**Pruned + 5-trial under:** #25 ([B1] scope manifest as fenced markdown — this tombstone)

## Function mapping

| Legacy function | Migrated to |
|---|---|
| `_extract_scope_from_design` (pipeline-stages.sh:38-71) | `plugins/agent/design/plugin.sh:444-467` — `_extract_scope_from_design` + `plugins/agent/build/plugin.sh:1554-1577` — `_extract_scope_from_design` |

## Behavioral differences from legacy

- **Signature**: legacy took `[artifacts_dir]` and resolved `design.md` from env; migrated takes `<design_md_path>` directly.
- **Output**: legacy emitted `pipeline.scope_manifest_missing` / `pipeline.scope_manifest_loaded` events; migrated returns CSV, no event emission.
- **Parser**: legacy used `awk`; migrated uses a `while IFS= read -r` loop.

## Parallel implementation note

`_impact_extract_scope_from_design` in `plugins/agent/impact/plugin.sh:68-83` is
identical in behavior to the migrated function but was added independently for the
impact plugin. It is NOT part of the A1 migration and was NOT pruned here.

## Remaining blockers

- `legacy/scripts/lib/pipeline-stages.sh` cannot be `git rm`'d because `_compute_scope_violations`,
  `_validate_dod_no_excluded_paths`, `prune_context_section`, `guard_prompt_size`, and stage-loader
  helpers remain unmigrated. The `git rm` of the file is deferred to the issues that migrate those functions.

## 5-trial checklist

- [x] T1: `_extract_scope_from_design` from `plugins/agent/design/plugin.sh` extracts CSV correctly from a fenced ` ```scope ` block (tests/unit/scope-manifest-b1-regression-test.sh [SPEC-1])
- [x] T1b/T1c/T1d: missing file → empty; no scope block → empty; blank lines stripped (tests/unit/scope-manifest-b1-regression-test.sh [SPEC-2])
- [x] T3: `grep -c "legacy-citation.*pipeline-stages.sh:38" plugins/agent/design/plugin.sh` returns count > 0 — citation discoverable in new tree (tests/unit/scope-manifest-b1-regression-test.sh [SPEC-3])
- [x] T4: KEEPERS §H row for `pipeline-stages.sh:42` mentions `plugins/agent/design/` — mapping table matches actual code location (tests/unit/scope-manifest-b1-regression-test.sh [SPEC-4])
- [x] T5: `_extract_scope_from_design` pruned from `legacy/scripts/lib/pipeline-stages.sh`; simulation of removal proves `_scope_source` stays `"plan"` when function returns empty (tests/unit/scope-manifest-b1-regression-test.sh [SPEC-5])
