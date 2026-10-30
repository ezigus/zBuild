# Security lens notes — issue #1951

## Files read
- tests/unit/event-schema-emitted-coverage-test.sh (full)
- config/event-schema.json (full)
- core/event-bus/known-types.sh (full)
- plugins/agent/security-lens/manifest.yaml (full)
- plugins/tool/merge/manifest.yaml (full)
- plugins/agent/security-lens/tests/security-lens-test.sh (full)
- tests/unit/merge-v2-result-test.sh (first 80 lines)
- docs/adr/ADR-001-plugin-contract.md (tail, Enforced-by section)

## Injection trace (manifests → test logic)

Event names from `eb_manifest_events` reach the new code paths in sections 5 and 6:

**Section 5 (SPEC-1):**
- `_1951_pev` → `${_1951_pev%.*}` (parameter expansion, no exec)
- `_1951_ns` → `grep -qxF "$_1951_ns" <<< "$_1951_plugin_ns"` (fixed-string, safe)
- `_1951_t` → error message string (no eval, safe)

**Section 6 (SPEC-2):**
- `_1951_ev2` → `[[ "$_1951_ev2" == "plugin.${_1951_pname2_ns}."* ]]` (glob on right side, data on left — generally safe but see finding #2)
- `_1951_ev2` → `grep -qE "$_ENGINE_OWNED_NS_RE" <<< "$_1951_ev2"` (data in here-string, pattern is hardcoded — safe)
- `_1951_ev2` → error message array, then `assert_fail` (no eval, safe)

No command injection paths found.

## Credential/secret exposure
None. No credentials in any touched file.

## Path traversal
`find "$REPO_ROOT/plugins" -maxdepth 3` limits depth. `$REPO_ROOT` is derived from `cd ... && pwd` — robust against `..` in `BASH_SOURCE` relative path. No path traversal found.

## Input validation at system boundaries

### Finding 1: _ENGINE_OWNED_NS_RE is a new hardcoded enumeration
Line 217 of the test. The change removes _PLUGIN_NS_RE but introduces _ENGINE_OWNED_NS_RE as a hardcoded list of 21 engine-owned namespace prefixes. If a new engine namespace is added (e.g., `auth`) without updating this regex, plugins could claim events in that namespace and the SPEC-2 guard would not catch it. This is the symmetric risk to the one the change was fixing. The design explicitly accepts this tradeoff (engine namespaces are smaller and more stable than plugin namespaces). Severity: LOW, introduced: true.

### Finding 2: Plugin directory basename used in glob pattern without metachar sanitization
Lines 224-232. `_1951_pname2_ns="${_1951_pname2//-/_}"` replaces only hyphens with underscores. A plugin directory name containing glob metacharacters (`[`, `]`, `*`, `?`) would survive into the pattern `[[ "$_1951_ev2" == "plugin.${_1951_pname2_ns}."* ]]`. In bash `[[ ]]`, the right-hand side of `==` is treated as a glob pattern — unquoted metacharacters would be interpreted, potentially matching events from unrelated plugins and falsely exempting them from the engine-namespace check. Plugin directory names are under repository control, so this requires a contributor-level adversary. Severity: LOW, introduced: true.

### Finding 3: Manifest event names not validated before namespace extraction
Lines 174-181 (SPEC-1). `eb_manifest_events` is called directly without calling `eb_manifest_events_invalid_v` to pre-filter malformed names. A single-component event name (e.g., `persist` with no dots) would survive `eb_manifest_events` (awk only parses structure, does not validate names). For such a name, `${_1951_pev%.*}` returns the name unchanged (no dot to strip), adding `persist` as a namespace rather than the intended full-dotted prefix. This could pollute the plugin-ns set — e.g., a manifest declaring bare `plugin` (no dot) would add `plugin` to the plugin-ns set and falsely flag engine events like `plugin.result`. In practice, `validate_manifest` (which calls `eb_manifest_events_invalid_v`) catches this before the test runs, so exploitation requires a pre-commit bypass. Severity: LOW, introduced: true.

## Trust boundary / design observation
The `_ENGINE_OWNED_NS_RE` list is new code introduced by this change. All three findings are introduced by this change. None of the changed configuration files (event-schema.json, manifests) introduce security issues — the removal of `plugin.result` from two plugin manifests and persist/hydrate events from the engine schema are correct boundary adjustments.

## Score
Three low-severity findings, no medium/high/critical. Score: 7.
