# Correctness lens notes — issue #1951

## Files read
- tests/unit/event-schema-emitted-coverage-test.sh (full, 342 lines)
- plugins/agent/security-lens/tests/security-lens-test.sh (full, 777 lines)
- tests/unit/merge-v2-result-test.sh (full, 378 lines)
- core/event-bus/known-types.sh (full, 229 lines)
- tests/unit/lint-adr-enforced-by-test.sh (lines 1-160)
- docs/adr/ADR-001-plugin-contract.md (lines 335-355)
- plugins/tool/merge/manifest.yaml (full)
- plugins/agent/security-lens/manifest.yaml (full)
- plugins/tool/persist/manifest.yaml (grep)
- plugins/tool/hydrate/manifest.yaml (grep)
- plugins/tool/pr-open/manifest.yaml (grep)
- config/event-schema.json (lines 1-60)

## Key logic verified

### SPEC-1 (section 5, lines 148-200)
Uses all-but-last namespace extraction: `${event%.*}` removes shortest suffix after last dot.
- `persist.start` → `persist` ✓
- `plugin.pr_open.branch_fallback_used` → `plugin.pr_open` ✓ (avoids false-flagging engine plugin.* events)
- Persist plugin declares BOTH 2-component events (adding `persist` to namespace set) AND 3-component events. Current repo: no false negatives.

LATENT ISSUE: If a plugin declared ONLY 3-component events (no 2-component) in a namespace, and the engine config had a 2-component event in that top-level namespace, the guard would miss it. Not currently reachable.

### SPEC-2 (section 6, lines 202-246)
Uses `_ENGINE_OWNED_NS_RE` ERE against each plugin event. Exception: `plugin.<dirname_ns>.*` events are allowed for each plugin's own sub-namespace. All 22 engine namespaces from the design are present in the regex.

- Uses `grep -qE ... <<< "$var"` (here-string, not pipe) — no SIGPIPE risk ✓
- Exception check `[[ "$_1951_ev2" == "plugin.${_1951_pname2_ns}."* ]]` correctly uses glob matching ✓
- After SPEC-4 removes `plugin.result` from security-lens and merge, SPEC-2 should pass ✓

### SPEC-3 checks (lines 248-285)
- Negative check: no persist.*/hydrate.* in engine config — `grep -E ... || true` pattern prevents pipefail exit ✓
- Positive check: persist/hydrate manifests still have their events ✓
- `eb_manifest_events` for non-existent file produces no output (awk's 2>/dev/null swallows error) → check correctly fails ✓

### SPEC-4 meta-assertions (lines 287-322)
Checks that specific OLD assertion text is absent from security-lens-test.sh and merge-v2-result-test.sh.

ISSUE: `grep -qF "..." "$file" 2>/dev/null` — if `$file` doesn't exist, grep exits with status 2 (file error). The `if` construct treats status 2 as false → `assert_pass`. Silent false pass if test files are deleted.

Currently not a problem (files exist), but the guard itself could be silently bypassed.

### SPEC-6 self-referential check (lines 324-338)
Correctly constructs `_PLUGIN_NS_RE` by splitting across two quoted segments to avoid literal occurrence.
`'_PLUGIN_NS'"_RE"` in the file is NOT the string `_PLUGIN_NS_RE` (quote chars interrupt the sequence).
`grep -qF "_PLUGIN_NS_RE"` on the file correctly returns non-zero → `! grep ...` → `assert_pass` ✓

### Sigpipe antipattern check
Multi-stage pipes at lines 55-62 and 105-108 pipe into `grep -vE` (not `grep -q`) and `sort -u` (not `head`). Both are readers that consume ALL stdin — no early-exit sigpipe risk. ✓

## Merge manifest after change
`provides:` section has only `result_contract: 3` and `role: merge_executor`. No `events:` block. `eb_manifest_events` returns nothing for this manifest. Correct — merge plugin now declares no events. ✓

## engine config
After change: no persist.* or hydrate.* events. `plugin.result` remains (engine-owned). ✓

## Conclusions
Two low-severity issues:
1. SPEC-4 meta-assertions false-pass on missing test file (low, introduced)
2. SPEC-1 all-but-last gap for top-level namespace conflicts with 3-component-only plugins (low, introduced, not reachable in current codebase)

Score: 8/10
