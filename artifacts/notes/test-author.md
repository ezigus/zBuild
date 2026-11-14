# Test Author Notes — Issue #1700 (platform probe)

## Status: INCOMPLETE — no test files written yet (ran out of time twice)

## What I know

### Base code (before this change)
- `scripts/lib/compat.sh`: `zbuild_sed_inplace` checks `$ZBUILD_PLATFORM == "macos"` to pick sed form. `zbuild_stat_size` does same (no callers). No probe variable.
- `scripts/lib/helpers.sh`: `_zb_target_mode_v` checks `$ZBUILD_PLATFORM == "macos"` and runs stat twice as fallback. `_ZB_UMASK` is a module-level var set at load time (good pattern to follow).

### Design decision
- Both files will store a probe result in a module-level variable at load time
- Variable name conventions in codebase: `_ZB_` prefix for module-level vars
- The design does NOT name specific variable names; tests should be behavioral

## Tests to write

### File 1: `tests/unit/platform-probe-test.sh` (new)
Covers: DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3

Pattern from existing tests:
```bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"   # or compat.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "..."
setup_test_env "platform-probe"
...
cleanup_test_env
print_test_results
exit $((FAIL > 0))
```

**DSPRB-1** strategy: 
- Given: export ZBUILD_PLATFORM=macos; source compat.sh (in subshell to avoid polluting)
- When: zbuild_sed_inplace 's/old/new/' "$file"
- Then: file content changed + exit code 0
- Must FAIL on base code (Linux uses `sed -i ''` which fails on Linux)
- Use subshell: `( export ZBUILD_PLATFORM=macos; source compat.sh; zbuild_sed_inplace ... )`

**DSPRB-2** strategy:
- Given: export ZBUILD_PLATFORM=macos; source helpers.sh (overrides compat.sh's platform detection)
- When: _zb_target_mode_v mode "$file"
- Then: $mode matches ^[0-7]{3,4}$
- Must FAIL on base code (Linux with ZBUILD_PLATFORM=macos uses stat -f '%Lp' which fails on Linux)
- Use subshell with ZBUILD_PLATFORM=macos override

**DSPRB-3** strategy (behavioral, no variable name needed):
- Source helpers.sh normally
- Wrap stat to log arguments: `stat() { printf '%s\n' "$*" >> "$CALLS"; command stat "$@"; }`
- Call _zb_target_mode_v on a file
- Verify log contains `-c` (GNU form), not only `-f` (BSD form)
- Must FAIL on base code (base code tries BSD first on non-macos, but actually base code tries GNU first on Linux — wait, need to re-check)
- Actually: base code uses `stat -c '%a'` on Linux (GNU first). New code should probe and use GNU form.
- BUT: on Linux, base code ALREADY uses GNU form first. The difference is that new code does it via probe, not platform name.
- For DSPRB-3 to fail on base code: I need to test with ZBUILD_PLATFORM=macos set. With base code + ZBUILD_PLATFORM=macos, it tries stat -f first (BSD form). With new code + ZBUILD_PLATFORM=macos, it still uses stat -c (GNU) because it probed.
- So: set ZBUILD_PLATFORM=macos, source helpers.sh, call _zb_target_mode_v, check that stat -c was called

**DSPRB-4** strategy (count stat calls):
- Source helpers.sh
- Wrap stat: `stat() { echo "stat" >> "$CALLS"; command stat "$@"; }`
- Call _zb_target_mode_v once on existing file
- Count stat calls: must be exactly 1
- Must FAIL on base code: on Linux with ZBUILD_PLATFORM=macos, base code runs stat -f first, gets non-mode output, runs stat -c second = 2 calls

**DSPRB-5** strategy:
- Source compat.sh. Wrap sed to count calls per-call. 
- Actually: probe at load time means the probe ran during source. Then zbuild_sed_inplace should NOT probe again.
- Approach: use a tmp file; source compat.sh; install a sed counting wrapper AFTER sourcing; call zbuild_sed_inplace; count calls = 1 (actual edit only, no probe).
- If probe is per-call (base code or bad new code), there would be a probe attempt inside zbuild_sed_inplace.
- BUT: base code has NO probe at all (just ZBUILD_PLATFORM check), so it always starts 1 sed. The new code with per-call probe would start 2.
- So DSPRB-5 (the probe ran at LOAD TIME) fails on new code if probe is per-call, not on base code...
- Wait: DSPRB-5 says "must FAIL on the code as it was before this change". Base code has NO probe variable — it's empty. So checking that the probe variable is non-empty right after sourcing WILL fail on base code (variable doesn't exist).
- Alternative: check for a NEW module variable set by compat.sh. But we don't know the name.
- Best approach: Check that after sourcing compat.sh, there is a module variable starting with `_ZB_SED` (or similar) that is non-empty. Use `declare -p | grep '_ZB_SED'` to find it.
- Or: check specifically that there's a sed probe by trying to find ANY variable that holds either `-i ''` or just `-i` (the two possible probe results).

Actually cleanest approach for DSPRB-5: wrap sed to count calls during source; then call zbuild_sed_inplace with a counting wrapper; total sed calls during load > 0 (probe ran), and calls during the function = 1 (edit only).

Hmm, this is getting complex. Let me think more carefully.

On base code:
- During source of compat.sh: 0 sed calls (no probe)
- During zbuild_sed_inplace: 1 sed call (actual edit)

On new code (correct):
- During source of compat.sh: some sed calls (probe)
- During zbuild_sed_inplace: 1 sed call (actual edit, no re-probe)

On new code (incorrect — probe per call):
- During source of compat.sh: 0 sed calls
- During zbuild_sed_inplace: 2+ sed calls (probe + edit)

For DSPRB-5 to fail on BASE code AND pass on new CORRECT code, I need to verify the probe ran AT LOAD TIME. 

Approach: install a sed counter BEFORE sourcing. Source compat.sh. Check counter > 0 immediately after.
- Base code: counter = 0 → FAIL ✓
- New correct code: counter > 0 → PASS ✓

This works! Intercepting sed during source to count probe calls.

But wait — the probe of sed probably uses `sed --version` or runs sed on a temp file. If we wrap sed to count calls, it will count probe calls during source.

IMPORTANT: The compat.sh load guard (`[[ -n "${_ZBUILD_COMPAT_LOADED:-}" ]] && return 0`) means we must unset `_ZBUILD_COMPAT_LOADED` before re-sourcing in tests.

### File 2: `tests/unit/atomic-write-cost-test.sh` (edit existing)
Covers: DSBUD-1
- Add [DSBUD-1] tag to the W1 assertion "it starts cat, one stat and mv"
- This assertion already verifies exactly one stat call per atomic_write
- The stat probe at load time should NOT add per-call overhead (it ran once at load)

## Important implementation notes

### Subshell isolation for DSPRB-1 and DSPRB-2
Must source compat.sh/helpers.sh inside a subshell with ZBUILD_PLATFORM=macos so it doesn't affect the outer shell where helpers.sh is already loaded.

Must unset `_ZBUILD_COMPAT_LOADED` and `_ZBUILD_HELPERS_LOADED` before re-sourcing.

Pattern:
```bash
result=$(
    unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED
    export ZBUILD_PLATFORM=macos
    source "$REPO_ROOT/scripts/lib/compat.sh"
    # test body
    echo "$result_value"
)
```

### SIGPIPE rule
Never pipe into grep -q. Use here-strings or file-based grep.

### test-helpers.sh already sourced when sourcing helpers.sh
helpers.sh sources compat.sh. So for compat.sh tests, source compat.sh in a subshell to get a clean load.

## Next steps (pick up here)
1. Write tests/unit/platform-probe-test.sh with all 7 SPECs (DSPRB-1 through DSPRB-5, DSDEL-1, DSADR-3)
2. Edit tests/unit/atomic-write-cost-test.sh to add [DSBUD-1] tag to W1 stat assertion
3. Verify no SIGPIPE violations (no pipe into grep -q)
4. No hard-coded paths outside repo root
