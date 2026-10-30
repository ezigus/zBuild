# Performance lens notes — issue #1951

## Files examined
- tests/unit/event-schema-emitted-coverage-test.sh (full read, +193/-13 changed lines)
- core/event-bus/known-types.sh (eb_manifest_events, eb_compose_known_types)
- config/event-schema.json (11 entries removed — no algorithmic change)
- plugins/agent/security-lens/manifest.yaml, plugins/tool/merge/manifest.yaml (entries removed)
- docs/adr/ADR-001-plugin-contract.md, config/adr-enforcement-baseline.txt (docs/config only)

## Plugin count
44 manifest.yaml files under plugins/ (find output).

## Production code changes
None. All algorithmic changes are confined to tests/unit/event-schema-emitted-coverage-test.sh.
The engine code paths (core/, plugins/, scripts/) are unchanged; config and manifests only drop entries.

## New code patterns introduced by the change

### 1. Two additional `find` traversals over plugins/ (lines 167, 237)
Pre-existing: line 109 already does `find ... -maxdepth 3 -name 'manifest.yaml'`
and eb_compose_known_types (line 50) does the same internally.

The change adds:
- Line 167: `find "$REPO_ROOT/plugins" -maxdepth 3 -name 'manifest.yaml' -type f` for SPEC-1
- Line 237: `find "$REPO_ROOT/plugins" -maxdepth 3 -name 'manifest.yaml' -type f -exec dirname {} \;` for SPEC-2

Total find traversals in the test: 4 (1 inside eb_compose_known_types + lines 109, 167, 237).
All scan the same tree and return the same manifest paths. Introduced by this change: 2 extra.

### 2. Per-manifest eb_manifest_events in SPEC-2 loop (line 226, inside loop started line 219)
Section 6 loops over plugin dirs and calls `eb_manifest_events "$_1951_mf2"` per plugin.
With 44 plugins = 44 awk process spawns. Section 5 already collected all events in one batched
call (line 170, 1 awk spawn) — section 6 repeats the per-manifest parse independently.
Introduced by this change.

### 3. `find ... -exec dirname {} \;` spawns dirname per manifest (line 237)
Line 237 uses `-exec dirname {} \;` (semicolon form = one process per manifest = 44 dirname forks).
Could use `find -printf '%h\n'` or bash `${m%/*}` to avoid the forks entirely.
The same pattern pre-exists on line 109 (not introduced by this change), but line 237 is new.

### 4. Per-engine-event grep -qxF in section-5 loop (line 188)
Loop over engine events (N ≈ 80 based on schema size), each iteration forks a grep.
This is O(N_engine_events) grep processes. Introduced by this change.

### 5. Per-plugin-event grep -qE in section-6 inner loop (line 233)
For each plugin × each declared event, forks a grep with -E. With 44 plugins × ~3 events = ~130 grep forks.
Introduced by this change.

### 6. Bash string concatenation in namespace extraction loop (lines 175-178)
`_1951_plugin_ns+="${_1951_pev%.*}"$'\n'` accumulates into a growing string.
Bash string concatenation is O(N²) total work due to copying. For ~200 total plugin events,
this is negligible in practice but is technically quadratic. Introduced by this change.

## Severity assessment
All findings are in test code running once per CI invocation, NOT in any production hot path.
The dataset is bounded (44 manifests, ~80 engine types, ~200 plugin events total).
Estimated added wall-clock per CI run: ~500ms–1s (redundant find + awk + grep forks).
No O(N²) concern at production scale; datasets are small and stable.

Score: 8 — minor inefficiencies in test code, zero production impact.
