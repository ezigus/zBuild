# Implementation Plan: Fix Ruflo Memory Calls Process Leak (Issue #441)

**Issue**: Every loop iteration leaks child Node processes from `ruflo_with_timeout` → 385 leaked procs × ~4 MB = ~1.5 GB permanently held.

**Status**: Plan phase (detailed analysis complete)

---

## Root Cause Analysis

### Root Cause Hypothesis (Ranked by Likelihood)

**1. CONFIRMED — Process Group Not Isolated (95% confidence)**
   - Current: `ruflo_with_timeout` uses `pkill -TERM -P "$bg_pid"` to kill direct children only
   - Problem: When ruflo spawns Node → Node spawns grandchildren (agentdb workers, LLM processes), grandchildren's parent is Node, not `$bg_pid`
   - Evidence: 
     - `scripts/lib/ruflo-adapter.sh:416` — `pkill -TERM -P "$bg_pid"` only kills **direct children** by parent PID
     - Line 414 comment: "without a dedicated process group" — admits no process group isolation
     - Line 404: `( "$@" ) >"$_rft_tmp" &` — no `setsid` to create process group
   - Confirmation: When timeout fires, Node process is killed (line 418), but its children become orphaned and adopted by init

**2. SECONDARY — Incomplete Signal Propagation (40% confidence)**
   - Even if `pkill -TERM` fires, a 1-second gap between TERM and KILL (implicit in current code) may allow grandchildren to ignore SIGTERM
   - Evidence: No explicit `--kill-after` or grace period with `sleep` between TERM and KILL
   - How to confirm: Check if processes respond to SIGTERM or need SIGKILL

**3. TERTIARY — Exit Trap Not Cleaning Process Groups (20% confidence)**
   - `ruflo_cleanup` at line 290 does not explicitly kill process groups from failed `ruflo_with_timeout` calls
   - Evidence: `ruflo_cleanup` only called on EXIT, not after each `ruflo_with_timeout` timeout
   - How to confirm: Trace EXIT trap behavior during multi-iteration loop

### Evidence Gathered

| Item | Location | Finding |
|------|----------|---------|
| Function under test | `scripts/lib/ruflo-adapter.sh:373–437` | Uses `pkill -P` (direct children only), no `setsid` |
| Shell function spawn | Line 404 | `( "$@" ) >"$_rft_tmp" &` — no process group isolation |
| Child kill logic | Lines 415–419 | TERM kill via `pkill -P`, then `kill`, then `wait` |
| Grace period | Lines 407–421 | 1-second polling loop; no explicit TERM→KILL gap |
| Test coverage | `scripts/sw-ruflo-timeout-test.sh` | Tests FD cleanup and output, but NOT process cleanup |
| Process leak signal | Issue #441 | "385 leaked procs × 4 MB = 1.5 GB over ~260 iterations" |
| Related issue | `scripts/lib/ruflo-adapter.sh:396` | Issue #426 fixed FD hang with temp file; process leak is separate |

---

## Fix Strategy

**Approach**: Use POSIX process groups (`setsid` + negative PID in `kill`) to capture all descendants, then apply explicit TERM→KILL sequence with bash 3.2 compatibility.

**Core Changes**:
1. **Line 404**: Add `setsid` to create process group
2. **Lines 415–419**: Replace `pkill -P` with `kill -TERM -<negative-bg_pid>` (process group TERM)
3. **Add grace period**: Explicit `sleep 1` + `kill -KILL -<negative-bg_pid>` (process group KILL)
4. **Add test**: New Test 8 verifies zero orphaned processes after 10 consecutive timeouts
5. **Add integration check**: Smoke test measures baseline process count

---

## Files to Modify

1. **`scripts/lib/ruflo-adapter.sh`** — Process group isolation + TERM→KILL + cleanup
2. **`scripts/sw-ruflo-timeout-test.sh`** — Test 8 for orphan verification
3. **`scripts/sw-e2e-smoke-test.sh`** — Process baseline measurement

---

## Implementation Steps (In Order)

### Phase 1: Core Fix (ruflo-adapter.sh)

**Task 1.1**: Add helper function for process group kill
- **File**: `scripts/lib/ruflo-adapter.sh` (insert before line 373)
- **Acceptance**: Function handles both process group (`kill -s <sig> -<pid>`) and fallback (`pkill -P`)

**Task 1.2**: Modify background spawn to use setsid (line 404)
- **File**: `scripts/lib/ruflo-adapter.sh:404`
- **Change**: `( "$@" )` → `( setsid "$@" )`
- **Acceptance**: Subshell runs in its own process group

**Task 1.3**: Replace pkill -P with process group kill (line 416)
- **File**: `scripts/lib/ruflo-adapter.sh:416`
- **Change**: Call helper to send SIGTERM to entire process group
- **Acceptance**: Process group TERM sent to all descendants

**Task 1.4**: Add TERM→KILL grace period
- **File**: `scripts/lib/ruflo-adapter.sh` (after line 416)
- **Code**: `sleep 1` then `kill -KILL -<bg_pid>` to entire process group
- **Acceptance**: 1-second grace period, then SIGKILL to process group

**Task 1.5**: Verify temp cleanup executes regardless
- **File**: `scripts/lib/ruflo-adapter.sh:420`
- **Check**: `rm -f "$_rft_tmp"` still executes on all code paths
- **Acceptance**: No leaked temp files

### Phase 2: Regression Test

**Task 2.1**: Add Test 8 for process leak detection
- **File**: `scripts/sw-ruflo-timeout-test.sh` (after line 197)
- **Test**: Run 10 iterations of timeout, spawn grandchild per iteration, verify zero survivors
- **Acceptance**: Test 8 passes, no orphaned processes remain

**Task 2.2**: Update test comments
- **File**: `scripts/sw-ruflo-timeout-test.sh:2` (header comment)
- **Change**: Add "and process leak (#441)" to comment
- **Acceptance**: Comment reflects both issues #426 and #441

### Phase 3: Integration Check

**Task 3.1**: Add baseline process measurement to smoke test
- **File**: `scripts/sw-e2e-smoke-test.sh` (before first test)
- **Code**: Capture `pgrep -c -f "node|ruflo"` baseline
- **Acceptance**: Baseline printed at start of smoke test

**Task 3.2**: Add process delta check at smoke test end
- **File**: `scripts/sw-e2e-smoke-test.sh` (after final test)
- **Code**: Measure final process count, compute delta, assert ≤ 3
- **Acceptance**: Process delta reported in summary

---

## Task Checklist

- [ ] Task 1.1: Add `_kill_process_group` helper to ruflo-adapter.sh
- [ ] Task 1.2: Update line 404 to use `setsid`
- [ ] Task 1.3: Replace `pkill -P` with process group kill
- [ ] Task 1.4: Add `sleep 1` + SIGKILL to process group
- [ ] Task 1.5: Verify temp cleanup on all paths
- [ ] Task 2.1: Add Test 8 (10-iteration orphan check)
- [ ] Task 2.2: Update test header comment
- [ ] Task 3.1: Add baseline measurement to smoke test
- [ ] Task 3.2: Add process delta check at smoke test end
- [ ] Verify Test 8 passes with zero orphans
- [ ] Verify smoke test shows process delta ≤ 3
- [ ] Manual verification: 10 iterations with ≤1 proc delta per iteration

---

## Testing Approach

### Unit Tests
1. `bash scripts/sw-ruflo-timeout-test.sh`
   - All 8 tests pass (including new Test 8)
   - No "sleep 999" orphans survive

### Integration Tests
1. `bash scripts/sw-e2e-smoke-test.sh`
   - All smoke tests pass
   - Process delta ≤ 3 (allow variance)

### Manual Verification
```bash
# Run 10 iterations, measure leaked procs each time
for i in {1..10}; do
    _before=$(pgrep -c -f "node" 2>/dev/null || echo "0")
    bash -c 'source scripts/lib/ruflo-adapter.sh; ruflo_store "test-$i" "val-$i" 2>/dev/null' || true
    sleep 1
    _after=$(pgrep -c -f "node" 2>/dev/null || echo "0")
    _delta=$(( _after - _before ))
    echo "Iteration $i: delta=$_delta procs"
done
```
Success: All deltas ≤ 1

---

## Risk Analysis

| Risk | Mitigation |
|------|-----------|
| `setsid` unavailable | Fallback to `pkill -P` (still better than nothing) |
| Negative PID unsupported | Helper function catches error, falls back |
| Grace period too short | 1 sec is conservative; Node responds <100ms |
| Grace period too long | Acceptable; worst-case +260 secs for full test run |
| EXIT trap interference | Only called once; no re-entrancy issues |
| Flock contention | Process group kill ensures all locks released |
| Temp file not cleaned | Cleanup code runs regardless of kill path |

---

## Definition of Done

✓ **Code changes merged**:
- [ ] `_kill_process_group` helper implemented
- [ ] `setsid` added to line 404
- [ ] TERM→KILL sequence via process groups
- [ ] Grace period implemented
- [ ] Temp cleanup verified

✓ **Tests passing**:
- [ ] All 8 tests pass in sw-ruflo-timeout-test.sh
- [ ] Smoke test shows delta ≤ 3
- [ ] Manual 10-iteration test shows delta ≤ 1/iteration

✓ **Metrics verified**:
- [ ] **Zero new orphaned processes** after timeout
- [ ] **No FD hang regression** (Tests 1–7 still pass)
- [ ] **10-iteration manual test** shows no unbounded leak

---

## Alternatives Considered

| Alternative | Pros | Cons | Why Not |
|-------------|------|------|---------|
| Kill by name (`pkill -f "ruflo"`) | Simple | Kills unrelated processes, broad blast radius | Too risky |
| GNU timeout --kill-after | Standard tool | Not on macOS, must fallback anyway | Bash 3.2 requires custom |
| EXIT trap only | Single cleanup point | Doesn't clean mid-loop; 1.5GB leak persists | Doesn't solve issue |
| **Process groups + TERM→KILL** | **Captures all descendants** | **Slightly more code** | **Selected — POSIX, reliable, works in bash 3.2+** |

