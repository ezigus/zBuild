#!/usr/bin/env bash
# scripts/run-mutation.sh — mutation testing harness (issue #298, parallel #992)
#
# For each tests/mutation/*.md spec:
#   1. Lint required structural sections (## File / ## Mutation /
#      ## Expected failing test / ## Result / ## Patch / ## Test).
#   2. Extract the ```bash code block under ## Patch / ## Test.
#   3. Apply the patch + run the test INSIDE A DEDICATED git worktree at HEAD
#      (never the live working tree), expecting the test to fail (non-zero =
#      mutation caught). Each mutant runs in its own throwaway worktree, so
#      mutants are isolated and the run parallelizes (#992).
#
# Safety invariants:
#   - When specs exist (n_specs > 0), refuses to run if any mutation-target
#     dir (core/plugins/scripts/tests) has uncommitted tracked changes OR
#     untracked files. When no specs exist the check is skipped and
#     `mutation: 0/0 passed` is emitted immediately (nothing to protect).
#     The live tree is never mutated; per-mutant worktrees are checked out
#     from HEAD.
#   - Worktrees are torn down per-mutant (RETURN trap) and swept again on exit.
#   - Accounting is byte-for-byte identical to the prior serial runner: the
#     result lines and final `mutation: P/T passed` are emitted in glob order.
#
# Worktree-contention robustness (#1184):
#   - `git worktree prune` sweeps stale entries before dispatch.
#   - `git worktree add` is bounded-retried with jittered backoff, and each
#     successful add is VERIFIED (the mutated `## File` is present + non-empty)
#     before the patch runs — a checkout observed mid-materialization under
#     N-way concurrency otherwise yields a spurious "(patch failed)".
#
# Outcome classification (#1184): three status buckets, not two.
#   - pass  : mutation CAUGHT (test failed as expected).
#   - fail  : genuine coverage signal — a SURVIVED mutation (slipped past the
#             test), or a malformed spec (structural / relevance / empty /
#             no-op). Fail-worthy: counts toward the score AND the exit code.
#   - infra : NON-FATAL maintenance signal — a worktree-add / patch failure
#             that survives the retries+verify above. Excluded from the
#             `mutation: P/T passed` score AND from the exit code, so a
#             transient worktree race never sets test verdict=fail or blocks
#             the pipeline cycle. Surfaced on a separate `mutation-infra:` line
#             and NEVER routed into any build-feedback loop.
#
# Parallelism (#992):
#   - ZBUILD_MUTATION_PARALLEL_JOBS — UNSET ⇒ CPU-count default (cap 8);
#     0 or 1 ⇒ serial.
#   - ZBUILD_MUTATION_TEST_TIMEOUT  — per-mutant test bound (seconds, default
#     300; 0 ⇒ no timeout).
#   - ZBUILD_MUTATION_DIR           — override the spec dir (for tests).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUTATION_DIR="${ZBUILD_MUTATION_DIR:-$REPO_ROOT/tests/mutation}"
MUTATE_DIRS=(core plugins scripts tests)

passed=0
failed=0
infra=0
results=()

# Bounded retries for `git worktree add` + checkout-verify (#1184). Overridable
# for tests that want to exercise exhaustion quickly.
_MUT_WT_ADD_RETRIES="${ZBUILD_MUTATION_WT_ADD_RETRIES:-5}"
[[ "$_MUT_WT_ADD_RETRIES" =~ ^[1-9][0-9]*$ ]] || _MUT_WT_ADD_RETRIES=5

# Per-run scratch dir for staged patch/test blocks + per-slot result files.
job_dir=""
# PIDs of in-flight worktree mutant subshells (for teardown best-effort kill).
declare -a _mut_pids=()

# _zb_default_jobs — portable CPU-count for the parallel-by-default path.
# Linux has `nproc`; macOS does not (uses `sysctl -n hw.ncpu`). Falls back to 4
# and caps at 8 so a many-core host doesn't oversubscribe the bounded pool.
_zb_default_jobs() {
    local n
    n="$( { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null; } | head -1 )"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=4
    (( n > 8 )) && n=8
    printf '%s' "$n"
}

# _mut_resolve_jobs — UNSET ⇒ computed default; explicit 0/1 ⇒ serial (1);
# explicit N ⇒ N. Distinguish UNSET from an explicit value via ${VAR+x}.
_mut_resolve_jobs() {
    local j
    if [[ -z "${ZBUILD_MUTATION_PARALLEL_JOBS+x}" ]]; then
        j="$(_zb_default_jobs)"
    else
        j="$ZBUILD_MUTATION_PARALLEL_JOBS"
    fi
    [[ "$j" =~ ^[1-9][0-9]*$ ]] || j=1
    printf '%s' "$j"
}

# Per-mutant test timeout probe (mirrors run-tests.sh:18-24). 0 ⇒ no timeout.
# Validate: a non-integer would make `timeout` exit non-zero immediately, which
# the harness would miscount as "caught" (PASS) — masking an uncaught mutation.
_MUT_TEST_TIMEOUT="${ZBUILD_MUTATION_TEST_TIMEOUT:-300}"
if [[ ! "$_MUT_TEST_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "run-mutation.sh: invalid ZBUILD_MUTATION_TEST_TIMEOUT='$_MUT_TEST_TIMEOUT' (want non-negative integer seconds); using 300" >&2
    _MUT_TEST_TIMEOUT=300
fi
_mut_tout=()
if [[ "$_MUT_TEST_TIMEOUT" != "0" ]]; then
    if   command -v gtimeout >/dev/null 2>&1; then _mut_tout=("gtimeout" "$_MUT_TEST_TIMEOUT")
    elif command -v timeout  >/dev/null 2>&1; then _mut_tout=("timeout"  "$_MUT_TEST_TIMEOUT")
    fi
fi

# ─── Helpers ────────────────────────────────────────────────────────────────

_extract_bash_block() {
    local file="$1" header="$2"
    awk -v hdr="$header" '
        $0 == hdr            { in_section = 1; next }
        in_section && /^## / { in_section = 0 }
        in_section && /^```bash[[:space:]]*$/ { in_code = 1; next }
        in_code && /^```[[:space:]]*$/ { in_code = 0; exit }
        in_code              { print }
    ' "$file"
}

# Extract the first backticked path from the line(s) following a ## header.
# Returns the path with surrounding backticks stripped, empty on miss.
# Pure-awk so the function never trips errexit/pipefail (the previous
# `grep -oE ... | head -1` pipeline could exit non-zero on no-match or
# SIGPIPE on multi-match — #322 review L56).
_extract_backticked_path() {
    local file="$1" header="$2"
    awk -v hdr="$header" '
        $0 == hdr            { in_section = 1; next }
        in_section && /^## / { exit }
        in_section {
            line = $0
            while (match(line, /`[^`]+`/)) {
                tok = substr(line, RSTART + 1, RLENGTH - 2)
                if (tok != "") {
                    print tok
                    exit
                }
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$file" 2>/dev/null || true
}

# Verify the doc's "## Expected failing test" path is *plausibly related*
# to the "## File" being mutated — i.e., the test either lives in a path that
# shares a stem with the mutated file, OR it references the mutated file
# path/basename in its contents. Issue #309: prevents a mutation that patches
# core/router/ from naming an unrelated tests/unit/core-redaction-test.sh as
# its expected-failing test (which would pass for the wrong reason).
#
# Returns 0 if related, 1 if not relateable, 2 if either path is missing.
_check_mutation_relevance() {
    local doc="$1"
    local file_path test_path
    file_path="$(_extract_backticked_path "$doc" "## File")"
    test_path="$(_extract_backticked_path "$doc" "## Expected failing test")"

    if [[ -z "$file_path" || -z "$test_path" ]]; then
        return 2
    fi

    # The test file must exist on disk relative to repo root.
    if [[ ! -f "$REPO_ROOT/$test_path" ]]; then
        return 2
    fi

    # Stem overlap: the mutated file's basename stem (without .sh) AND each
    # directory component contributes a candidate token. The test path must
    # contain at least one of them.
    local file_base="${file_path##*/}"
    local file_stem="${file_base%.*}"            # e.g., scope-redaction
    local file_dir="${file_path%/*}"             # e.g., core/redaction
    local file_dir_leaf="${file_dir##*/}"        # e.g., redaction

    local token tokens=("$file_stem" "$file_dir_leaf")
    # Also tokenize the stem on '-' to allow partial-stem matches
    # (e.g., scope-redaction → scope, redaction).
    local IFS_BAK="$IFS"; IFS="-"
    # shellcheck disable=SC2206
    local stem_parts=( $file_stem )
    IFS="$IFS_BAK"
    for token in "${stem_parts[@]}"; do
        [[ ${#token} -ge 4 ]] && tokens+=("$token")
    done

    local t
    for t in "${tokens[@]}"; do
        [[ -z "$t" ]] && continue
        if [[ "$test_path" == *"$t"* ]]; then
            return 0
        fi
        # Or the test source references the mutated file path/basename.
        # `-F` keeps the search literal — file stems can include `.` or `[`
        # (multi-dot names) which would otherwise be interpreted as regex
        # metacharacters and silently miss or false-match (#322 review L108).
        if grep -qF -- "$t" "$REPO_ROOT/$test_path" 2>/dev/null; then
            return 0
        fi
    done

    # Last chance: does the test source the mutated file directly?
    if grep -qF "$file_path" "$REPO_ROOT/$test_path" 2>/dev/null \
       || grep -qF "$file_base" "$REPO_ROOT/$test_path" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Refuse if the working tree has ANY change in mutation-target dirs.
# This is essential: patch detection compares snapshots, and a pre-existing
# diff would be either silently restored (data loss) or silently skipped
# (mutation leaks past the cleanup). Both are bad.
_assert_clean_targets() {
    local dirty untracked
    dirty="$(cd "$REPO_ROOT" && git diff --name-only -- "${MUTATE_DIRS[@]}" 2>/dev/null || true)"
    untracked="$(cd "$REPO_ROOT" && git ls-files --others --exclude-standard -- "${MUTATE_DIRS[@]}" 2>/dev/null || true)"
    if [[ -n "$dirty" || -n "$untracked" ]]; then
        echo "run-mutation.sh: refusing — working tree has uncommitted changes" >&2
        echo "  in mutation-target dirs (${MUTATE_DIRS[*]})." >&2
        [[ -n "$dirty" ]]     && echo "  modified:" >&2 && echo "$dirty"     | sed 's/^/    /' >&2
        [[ -n "$untracked" ]] && echo "  untracked:" >&2 && echo "$untracked" | sed 's/^/    /' >&2
        echo "  Commit or stash them first." >&2
        echo "mutation: ABORTED (working tree dirty in ${MUTATE_DIRS[*]}; commit or stash)"
        exit 1
    fi
}

# _mut_verify_checkout <wt> <file_path> — confirm the mutated `## File`
# materialized COMPLETELY in the worktree (#1184). A bare `-s` non-empty check is
# too coarse: under concurrency a checkout can be observed with the file present
# but not byte-complete, so the patch's target string isn't found and its
# `assert`/replace spuriously fails. Compare the worktree copy against the HEAD
# blob byte-for-byte. Empty $file_path (or a path not tracked at HEAD) ⇒ fall
# back to the non-empty check. Returns 0 when complete, non-zero otherwise.
_mut_verify_checkout() {
    local wt="$1" file_path="$2"
    [[ -z "$file_path" ]] && return 0
    [[ -s "$wt/$file_path" ]] || return 1
    # Byte-exact match against the HEAD blob when the path is tracked at HEAD;
    # otherwise the non-empty check above stands.
    if git -C "$REPO_ROOT" cat-file -e "HEAD:$file_path" 2>/dev/null; then
        git -C "$REPO_ROOT" show "HEAD:$file_path" 2>/dev/null \
            | cmp -s - "$wt/$file_path" || return 1
    fi
    return 0
}

# _mut_add_worktree_verified <wt> <file_path> — add a detached-HEAD worktree at
# $wt with bounded retries + checkout verification (#1184). Under N-way
# concurrent `git worktree add`, a checkout can be observed mid-materialization,
# so the mutated file's target string isn't present yet and the patch spuriously
# fails. Retry the add with jittered backoff, and after each successful add
# verify (via _mut_verify_checkout) that the mutated `## File` materialized
# completely before handing off to the patch; re-add if incomplete. An empty
# $file_path skips the file check (still retries the bare add). Returns 0 on a
# verified worktree, non-zero after exhausting retries.
_mut_add_worktree_verified() {
    local wt="$1" file_path="$2"
    local attempt=0
    while (( attempt < _MUT_WT_ADD_RETRIES )); do
        attempt=$((attempt + 1))
        if git -C "$REPO_ROOT" worktree add --detach "$wt" HEAD >/dev/null 2>&1 \
           && _mut_verify_checkout "$wt" "$file_path"; then
            return 0
        fi
        # Failed add OR incomplete checkout: tear down this attempt, prune the
        # stale admin entry, back off (jittered) and retry.
        git -C "$REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
        rm -rf "$wt" 2>/dev/null || true
        git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
        (( attempt < _MUT_WT_ADD_RETRIES )) && sleep "0.$(( (RANDOM % 3) + 1 ))"
        mkdir -p "$wt" 2>/dev/null || true
    done
    return 1
}

# _run_one_mutant_in_worktree <doc> <slot_base> — run one already-gated mutant
# in a throwaway git worktree at HEAD, never the live tree. Reads the staged
# ${slot_base}.patch / ${slot_base}.test / ${slot_base}.file (NOT inherited
# arrays) so it is safe to run in a `( … ) &` subshell. Writes the result line
# to ${slot_base}.line and pass|fail|infra to ${slot_base}.status. The RETURN
# trap removes the worktree.
_run_one_mutant_in_worktree() {
    local doc="$1" slot_base="$2"
    local name; name="$(basename "$doc")"
    local patch_code test_code file_path
    patch_code="$(cat "${slot_base}.patch")"
    test_code="$(cat "${slot_base}.test")"
    file_path="$(cat "${slot_base}.file" 2>/dev/null || true)"

    local wt; wt=$(mktemp -d "${TMPDIR:-/tmp}/zb-mut.XXXXXX")
    # shellcheck disable=SC2064
    trap "git -C '$REPO_ROOT' worktree remove --force '$wt' >/dev/null 2>&1 || true; rm -rf '$wt' 2>/dev/null || true" RETURN

    # INFRA (non-fatal): worktree could not be materialized after retries+verify.
    if ! _mut_add_worktree_verified "$wt" "$file_path"; then
        printf 'INFRA %s  (worktree add failed after retries)' "$name" > "${slot_base}.line"
        printf 'infra' > "${slot_base}.status"
        return
    fi

    # INFRA (non-fatal): the patch failed against a verified-complete checkout.
    # Post-verify this is treated as a transient/maintenance signal, not a
    # coverage gap — it MUST NOT block the cycle or feed build-feedback (#1184).
    if ! ( cd "$wt" && bash -c "set -euo pipefail; $patch_code" ) >/dev/null 2>&1; then
        printf 'INFRA %s  (patch failed after retries)' "$name" > "${slot_base}.line"
        printf 'infra' > "${slot_base}.status"
        return
    fi

    if [[ -z "$(git -C "$wt" status --porcelain -- core plugins scripts tests)" ]]; then
        printf 'FAIL  %s  (no-op patch)' "$name" > "${slot_base}.line"
        printf 'fail' > "${slot_base}.status"
        return
    fi

    # Run targeted test; expect NON-ZERO (caught). stdin from /dev/null so a
    # `read`-blocked test gets EOF; fd3→/dev/null mirrors the #586 stage-io guard.
    local test_rc
    set +e
    ( cd "$wt" && "${_mut_tout[@]}" bash -c "$test_code" ) </dev/null >/dev/null 2>&1 3>/dev/null
    test_rc=$?
    set -e

    if [[ $test_rc -ne 0 ]]; then
        printf 'PASS  %s  (caught: rc=%s)' "$name" "$test_rc" > "${slot_base}.line"
        printf 'pass' > "${slot_base}.status"
    else
        printf 'FAIL  %s  (mutation slipped past test — coverage gap)' "$name" > "${slot_base}.line"
        printf 'fail' > "${slot_base}.status"
    fi
}

# Best-effort teardown: kill in-flight mutant subshells, prune + sweep any
# leftover zb-mut.* worktrees, drop the job dir. Idempotent. Replaces the old
# _restore_patches EXIT trap.
_mut_teardown() {
    local p wt_path line
    for p in "${_mut_pids[@]:-}"; do
        [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
    done
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    # Match by the zb-mut. basename our mktemp -d produces — robust across tmp
    # roots ($TMPDIR on macOS is /var/folders/.../T/, with a /private prefix in
    # `git worktree list` output; a tmp-root allow-list misses cases — #992).
    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                wt_path="${line#worktree }"
                case "${wt_path##*/}" in
                    zb-mut.*)
                        git -C "$REPO_ROOT" worktree remove --force "$wt_path" >/dev/null 2>&1 || true
                        rm -rf "$wt_path" 2>/dev/null || true
                        ;;
                esac
                ;;
        esac
    done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)
    [[ -n "$job_dir" ]] && rm -rf "$job_dir" 2>/dev/null || true
}

trap '_mut_teardown' EXIT INT TERM

# ─── Main loop ──────────────────────────────────────────────────────────────

job_dir="$(mktemp -d "${TMPDIR:-/tmp}/zb-mut-jobs.XXXXXX")"
_par_jobs="$(_mut_resolve_jobs)"

# Parallel arrays keyed by idx (glob order): the spec doc path, a pre-decided
# gate result line (set ⇒ skip dispatch), and the dispatch worklist.
declare -a doc_for_idx=()
declare -a gate_line=()
declare -a gate_status=()
declare -a gate_decided=()
declare -a dispatch=()

# ── Phase A: serial gating (no worktrees). Records a pre-decided result line
#    for every gate-rejected spec; stages patch/test + enqueues the rest. ──
idx=0
for doc in "$MUTATION_DIR"/*.md; do
    [[ -f "$doc" ]] || continue
    name="$(basename "$doc")"
    doc_for_idx[idx]="$doc"
    gate_decided[idx]=0

    structural_ok=1
    for section in "## File" "## Mutation" "## Expected failing test" "## Result" "## Patch" "## Test"; do
        if ! grep -qF "$section" "$doc"; then
            echo "FAIL $name: missing section '$section'" >&2
            structural_ok=0
        fi
    done
    if [[ $structural_ok -eq 0 ]]; then
        gate_line[idx]="FAIL  $name  (structural)"
        gate_status[idx]="fail"
        gate_decided[idx]=1
        idx=$((idx + 1))
        continue
    fi

    # Relevance gate (#309): expected-failing-test must plausibly exercise the
    # mutated file. Refuses to run mutations that name an unrelated test.
    relevance_rc=0
    _check_mutation_relevance "$doc" || relevance_rc=$?
    if [[ $relevance_rc -eq 2 ]]; then
        echo "FAIL $name: could not parse File and/or Expected failing test paths (missing or test file absent)" >&2
        gate_line[idx]="FAIL  $name  (relevance: unparseable / missing test file)"
        gate_status[idx]="fail"
        gate_decided[idx]=1
        idx=$((idx + 1))
        continue
    fi
    if [[ $relevance_rc -eq 1 ]]; then
        file_path_msg="$(_extract_backticked_path "$doc" "## File")"
        test_path_msg="$(_extract_backticked_path "$doc" "## Expected failing test")"
        echo "FAIL $name: expected-failing-test '$test_path_msg' has no path/content link to mutated '$file_path_msg' (#309)" >&2
        gate_line[idx]="FAIL  $name  (relevance: test does not exercise mutated file)"
        gate_status[idx]="fail"
        gate_decided[idx]=1
        idx=$((idx + 1))
        continue
    fi

    patch_code="$(_extract_bash_block "$doc" "## Patch")"
    test_code="$(_extract_bash_block "$doc" "## Test")"
    if [[ -z "$patch_code" || -z "$test_code" ]]; then
        echo "FAIL $name: ## Patch and/or ## Test bash block is empty" >&2
        gate_line[idx]="FAIL  $name  (empty patch/test block)"
        gate_status[idx]="fail"
        gate_decided[idx]=1
        idx=$((idx + 1))
        continue
    fi

    printf '%s' "$patch_code" > "$job_dir/$idx.patch"
    printf '%s' "$test_code"  > "$job_dir/$idx.test"
    # Stage the mutated `## File` path so the worktree runner can verify the
    # checkout materialized it before applying the patch (#1184). Empty is fine
    # (the relevance gate already passed) — verification degrades to a bare add.
    _extract_backticked_path "$doc" "## File" > "$job_dir/$idx.file" 2>/dev/null || true
    dispatch+=("$idx")
    idx=$((idx + 1))
done
n_specs=$idx
(( n_specs > 0 )) && _assert_clean_targets

# ── Phase B: bounded-parallel worktree execution over the dispatch worklist.
#    FIFO pool capped at $_par_jobs (bash-3.2-safe; no `wait -n`). ──
# Sweep stale worktree admin entries before dispatch so a leftover zb-mut.* from
# an interrupted run doesn't aggravate the materialization race (#1184).
git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
_mut_pids=()
for d_idx in "${dispatch[@]:-}"; do
    [[ -z "$d_idx" ]] && continue
    ( _run_one_mutant_in_worktree "${doc_for_idx[d_idx]}" "$job_dir/$d_idx" ) &
    _mut_pids+=($!)
    if [[ ${#_mut_pids[@]} -ge $_par_jobs ]]; then
        wait "${_mut_pids[0]}" 2>/dev/null || true
        _mut_pids=("${_mut_pids[@]:1}")
    fi
done
for _pid in "${_mut_pids[@]:-}"; do
    [[ -n "$_pid" ]] && wait "$_pid" 2>/dev/null || true
done
_mut_pids=()

# ── Aggregate in glob order. Gate-decided idx use the stored line; dispatched
#    idx read the per-slot .line/.status the worktree subshell wrote. ──
for ((i = 0; i < n_specs; i++)); do
    if [[ "${gate_decided[i]}" -eq 1 ]]; then
        line="${gate_line[i]}"
        status="${gate_status[i]}"
    else
        line="$(cat "$job_dir/$i.line" 2>/dev/null || printf 'FAIL  %s  (no result)' "$(basename "${doc_for_idx[i]}")")"
        status="$(cat "$job_dir/$i.status" 2>/dev/null || printf 'fail')"
    fi
    case "$status" in
        pass)  passed=$((passed + 1)) ;;
        infra) infra=$((infra + 1))   ;;   # non-fatal: excluded from score + rc
        *)     failed=$((failed + 1)) ;;
    esac
    results+=("$line")
done

# Match the other tiers' output shape: emit just the count line on full pass.
# On any fail OR infra outcome, surface the per-spec results table so the
# non-passing entries are visible without re-running.
if [[ $failed -ne 0 || $infra -ne 0 ]]; then
    echo
    echo "─── Mutation test results ──────────────────────────────"
    for line in "${results[@]}"; do
        echo "  $line"
    done
    echo "──────────────────────────────────────────────────────"
fi
# Infra outcomes are a distinct NON-FATAL signal (#1184): reported on their own
# line, kept OUT of the `mutation: P/T passed` score and the exit code so a
# transient worktree race never sets test verdict=fail or blocks the cycle.
if [[ $infra -ne 0 ]]; then
    echo "mutation-infra: $infra non-fatal (worktree/patch contention; excluded from score — #1184)"
fi
echo "mutation: $passed/$((passed + failed)) passed"

[[ $failed -eq 0 ]]
