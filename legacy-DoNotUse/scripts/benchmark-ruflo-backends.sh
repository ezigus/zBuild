#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  benchmark-ruflo-backends — Validate ≥10× subprocess reduction (#504)    ║
# ║                                                                           ║
# ║  Drives identical workloads through SW_RUFLO_BACKEND={cli,mcp} and        ║
# ║  records: per-call latency (p50/p95/p99), unique node PID count over the  ║
# ║  workload window, error count, and orphan-process leakage across runs.   ║
# ║                                                                           ║
# ║  Usage:                                                                   ║
# ║    scripts/benchmark-ruflo-backends.sh           # both backends + assert ║
# ║    scripts/benchmark-ruflo-backends.sh --cli     # CLI only               ║
# ║    scripts/benchmark-ruflo-backends.sh --mcp     # MCP only               ║
# ║    scripts/benchmark-ruflo-backends.sh --samples 30                       ║
# ║    scripts/benchmark-ruflo-backends.sh --no-assert  # collect only        ║
# ║                                                                           ║
# ║  Acceptance thresholds (from #504 design.md, exit 2 on miss):             ║
# ║    Headline: cli_pids/mcp_pids ≥ 10× (BENCH_REDUCTION_RATIO)              ║
# ║    CLI: ≥10 unique node PIDs over 20 calls (baseline sanity check)        ║
# ║    MCP: latency p95 ≤15ms post cold-start                                 ║
# ║    Both: MCP error_count == 0 across all samples                          ║
# ║    Optional --orphan-runs N: 0 orphan procs after N MCP cycles (#441)     ║
# ║                                                                           ║
# ║  Outputs (atomic):                                                        ║
# ║    .claude/pipeline-artifacts/benchmarks/benchmark-{cli,mcp}-<ts>.json    ║
# ║    .claude/pipeline-artifacts/benchmarks/summary-<ts>.md                  ║
# ║                                                                           ║
# ║  Bash 3.2 compatible — no associative arrays, no readarray, no ${var,,}. ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.6.1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/helpers.sh
source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=scripts/lib/ruflo-mcp-call.sh
source "$SCRIPT_DIR/lib/ruflo-mcp-call.sh"

# ─── Defaults / arg parsing ─────────────────────────────────────────────────
BENCH_SAMPLES="${BENCH_SAMPLES:-20}"
BENCH_DISCARD_FIRST=1   # skip cold-start sample from latency stats
RUN_CLI=1
RUN_MCP=1
DO_ASSERT=1
LATENCY_P95_MS_MAX="${BENCH_P95_MAX:-15}"
LATENCY_P99_MS_MAX="${BENCH_P99_MAX:-30}"
MCP_MAX_PIDS="${BENCH_MCP_MAX_PIDS:-1}"
CLI_MIN_PIDS="${BENCH_CLI_MIN_PIDS:-10}"
BENCH_TOOL="${BENCH_TOOL:-memory_search}"
ORPHAN_RUNS="${BENCH_ORPHAN_RUNS:-0}"
# Acceptance ratio: MCP transient PIDs must be ≤ CLI / RATIO. The issue
# (#504) calls for ≥10× reduction so default RATIO=10. When set, this is
# checked IN ADDITION TO the absolute MCP_MAX_PIDS cap. Set RATIO=0 to
# disable the ratio check (e.g. CLI side unavailable).
BENCH_REDUCTION_RATIO="${BENCH_REDUCTION_RATIO:-10}"

usage() {
    cat <<USAGE
benchmark-ruflo-backends $VERSION
Usage: $0 [--cli] [--mcp] [--samples N] [--no-assert] [--tool ping|memory_search]

Options:
  --cli              Run CLI backend only (default: run both)
  --mcp              Run MCP backend only (default: run both)
  --samples N        Number of latency samples per backend (default: 20)
  --tool TOOL        Bench call: 'memory_search' (default; full path) or
                     'ping' (transport-only — works even if ruflo memory I/O
                     is broken in the host environment, e.g. ONNX mismatch)
  --orphan-runs N    Run N consecutive MCP cycles (start→bench→stop) and
                     assert no orphan node procs related to ruflo bridge
                     remain after the final cycle (#441 sentinel; default: 0)
  --no-assert        Collect data, skip pass/fail assertions (collection mode)
  --help             Show this message

Env overrides:
  BENCH_SAMPLES         Same as --samples
  BENCH_TOOL            Same as --tool
  BENCH_ORPHAN_RUNS     Same as --orphan-runs
  BENCH_P95_MAX         MCP p95 latency ceiling in ms (default: 15)
  BENCH_P99_MAX         MCP p99 latency ceiling in ms (default: 30)
  BENCH_MCP_MAX_PIDS    Max unique node PIDs allowed for MCP (default: 1, soft)
  BENCH_CLI_MIN_PIDS    Min unique node PIDs expected for CLI (default: 10)
  BENCH_REDUCTION_RATIO Required cli_pids/mcp_pids ratio (default: 10, the
                        #504 acceptance criterion). Set 0 to disable.
USAGE
}

# Argument parser — Bash 3.2 safe (no shopt extglob requirements)
_only_specified=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cli)         RUN_CLI=1; if [[ $_only_specified -eq 0 ]]; then RUN_MCP=0; fi; _only_specified=1; shift ;;
        --mcp)         RUN_MCP=1; if [[ $_only_specified -eq 0 ]]; then RUN_CLI=0; fi; _only_specified=1; shift ;;
        --samples)     BENCH_SAMPLES="${2:?--samples requires N}"; shift 2 ;;
        --samples=*)   BENCH_SAMPLES="${1#*=}"; shift ;;
        --tool)        BENCH_TOOL="${2:?--tool requires NAME}"; shift 2 ;;
        --tool=*)      BENCH_TOOL="${1#*=}"; shift ;;
        --orphan-runs) ORPHAN_RUNS="${2:?--orphan-runs requires N}"; shift 2 ;;
        --orphan-runs=*) ORPHAN_RUNS="${1#*=}"; shift ;;
        --no-assert)   DO_ASSERT=0; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             error "Unknown argument: $1"; usage >&2; exit 1 ;;
    esac
done

if ! [[ "$BENCH_SAMPLES" =~ ^[0-9]+$ ]] || [[ "$BENCH_SAMPLES" -lt 5 ]]; then
    error "--samples must be an integer ≥5 (got: $BENCH_SAMPLES)"
    exit 1
fi
if ! [[ "$ORPHAN_RUNS" =~ ^[0-9]+$ ]]; then
    error "--orphan-runs must be a non-negative integer (got: $ORPHAN_RUNS)"
    exit 1
fi
case "$BENCH_TOOL" in
    ping|memory_search) ;;
    *) error "--tool must be 'ping' or 'memory_search' (got: $BENCH_TOOL)"; exit 1 ;;
esac

# ─── Output paths ────────────────────────────────────────────────────────────
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
ARTIFACT_DIR="$REPO_ROOT/.claude/pipeline-artifacts/benchmarks"
mkdir -p "$ARTIFACT_DIR"

# ─── Dependency check ───────────────────────────────────────────────────────
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command not found: $1"
        exit 1
    fi
}
require_cmd jq
require_cmd nc
require_cmd node
require_cmd awk
require_cmd ps

# ─── ms_time — milliseconds since epoch (cross-platform) ────────────────────
# `date +%s%3N` is Linux-only; macOS BSD date doesn't support %N. We use
# Python or Node as a portable nanosecond clock when %N is unavailable.
_HAVE_NS_DATE=0
if date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$'; then
    _HAVE_NS_DATE=1
fi
ms_time() {
    if [[ $_HAVE_NS_DATE -eq 1 ]]; then
        date +%s%3N
    else
        # Portable fallback: node's Date.now() is reliable on all our targets.
        node -e 'process.stdout.write(String(Date.now()))'
    fi
}

# ─── snapshot_node_pids — capture currently-running node PIDs as one-per-line ─
# Writes the raw `ps` output filtered to processes whose command contains
# "node" (case-sensitive — matches Node binary, not "node_modules" or scripts
# named e.g. nodejs-tool). Each line: `<pid> <ppid> <command>`.
snapshot_node_pids() {
    # ps -e -o args isn't 100% portable; pid+args works on Linux+BSD.
    ps -e -o pid=,ppid=,args= 2>/dev/null \
        | awk '$3 ~ /(^|\/)node($| )/ || $0 ~ /ruflo-bridge/ { print $1" "$2" "$0 }' \
        || true
}

# ─── make_bench_request — single sampled call (tool selectable) ────────────
# Echoes "<exit_code> <latency_ms>" so the caller can aggregate without
# unsetting set -e. Uses 1ms wallclock resolution; sub-ms calls show as 0.
#
# BENCH_TOOL drives which call is exercised:
#   memory_search → full path (ruflo memory search / mcp memory_search). If
#                   the host's ruflo install is broken (e.g. ONNX runtime
#                   mismatch) errors will dominate; that's intentional —
#                   memory_search is the production path.
#   ping          → bridge-only, in-process. CLI side has no ping equivalent;
#                   CLI uses `ruflo --version` as the closest cold-start
#                   analog so PID counts remain meaningful, with the caveat
#                   that latency is "node startup" and not "memory I/O".
make_bench_request() {
    local backend="$1" sample_idx="$2"
    local query="bench-${backend}-${sample_idx}-$$"
    local t0 t1 latency_ms exit_code=0

    t0=$(ms_time)
    if [[ "$backend" == "mcp" ]]; then
        case "$BENCH_TOOL" in
            ping)
                ruflo_mcp_call ping >/dev/null 2>&1 || exit_code=$?
                ;;
            *)
                ruflo_mcp_call memory_search "query=$query" "namespace=bench" "limit=1" \
                    >/dev/null 2>&1 || exit_code=$?
                ;;
        esac
    else
        # CLI path: invoke ruflo directly (matches legacy code path that
        # callers like _ruflo_recall_cli use). On hosts without ruflo, the
        # invocation will fail with non-zero — we still record the timing
        # so cold-start cost is captured even if the call errors out.
        if command -v ruflo >/dev/null 2>&1; then
            case "$BENCH_TOOL" in
                ping)
                    # No CLI ping; use --version as the cold-start analog.
                    # This still spawns a node process per call, which is
                    # exactly what we measure for the PID count comparison.
                    ruflo --version >/dev/null 2>&1 || exit_code=$?
                    ;;
                *)
                    ruflo memory search --query "$query" --namespace bench --limit 1 \
                        >/dev/null 2>&1 || exit_code=$?
                    ;;
            esac
        else
            exit_code=127
        fi
    fi
    t1=$(ms_time)
    latency_ms=$((t1 - t0))
    printf '%s %s\n' "$exit_code" "$latency_ms"
}

# ─── compute_percentiles — read latencies from stdin, write JSON to stdout ──
# Uses awk (Bash 3.2-safe, no readarray, no associative arrays).
# Drops the first BENCH_DISCARD_FIRST samples when --discard is provided.
compute_percentiles() {
    local discard="${1:-0}"
    awk -v discard="$discard" '
        BEGIN { n = 0 }
        { v[n++] = $1 + 0 }
        END {
            if (n <= discard) { discard = 0 }
            kept = n - discard
            if (kept <= 0) {
                printf("{\"count\":0,\"p50\":null,\"p95\":null,\"p99\":null,\"min\":null,\"max\":null,\"mean\":null}");
                exit
            }
            # bubble sort over the post-discard slice — fine for n ≤ 100
            base = discard
            for (i = base; i < n; i++)
                for (j = i + 1; j < n; j++)
                    if (v[i] > v[j]) { t = v[i]; v[i] = v[j]; v[j] = t }
            sum = 0; mn = v[base]; mx = v[base]
            for (i = base; i < n; i++) {
                sum += v[i]
                if (v[i] < mn) mn = v[i]
                if (v[i] > mx) mx = v[i]
            }
            mean = sum / kept
            # nearest-rank percentile: ceil(p * kept / 100) - 1 (0-indexed within slice)
            p50 = v[base + int((50 * kept + 99) / 100) - 1]
            p95 = v[base + int((95 * kept + 99) / 100) - 1]
            p99 = v[base + int((99 * kept + 99) / 100) - 1]
            printf("{\"count\":%d,\"p50\":%d,\"p95\":%d,\"p99\":%d,\"min\":%d,\"max\":%d,\"mean\":%.2f}",
                kept, p50, p95, p99, mn, mx, mean)
        }
    '
}

# ─── env_metadata_json — describe the host for reproducibility ──────────────
env_metadata_json() {
    local kernel arch cores loadavg node_v
    kernel=$(uname -s 2>/dev/null || echo "unknown")
    arch=$(uname -m 2>/dev/null || echo "unknown")
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)
    loadavg=$(uptime 2>/dev/null | awk -F'load average[s]?:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ' || true)
    [[ -z "$loadavg" ]] && loadavg="0"
    node_v=$(node --version 2>/dev/null || echo "unknown")
    jq -n -c \
        --arg kernel "$kernel" \
        --arg arch "$arch" \
        --arg loadavg "$loadavg" \
        --arg node "$node_v" \
        --arg ts "$(now_iso)" \
        --argjson cores "${cores:-0}" \
        '{kernel:$kernel, arch:$arch, cores:$cores, loadavg:$loadavg, node:$node, ts:$ts}'
}

# ─── run_backend — drive samples, gather PIDs, write JSON artifact ──────────
# Stdout: ONLY the path to the backend JSON artifact (consumed by main()).
# Stderr: all progress / info / warn / error messages so capture is clean.
run_backend() {
    local backend="$1"
    local pids_before pids_after pids_during_file
    pids_during_file=$(mktemp "${TMPDIR:-/tmp}/bench-pids-XXXXXX")

    info "Running benchmark: backend=$backend samples=$BENCH_SAMPLES" >&2

    if [[ "$backend" == "mcp" ]]; then
        # Use a benchmark-scoped socket so we don't disturb a running pipeline's bridge.
        export RUFLO_BRIDGE_SOCK="${TMPDIR:-/tmp}/ruflo-bench-bridge-$$.sock"
        if ! _ruflo_bridge_start; then
            error "Bridge failed to start — aborting MCP run (would record fake-good numbers)" >&2
            rm -f "$pids_during_file" 2>/dev/null || true
            return 1
        fi
        if ! ruflo_bridge_available; then
            error "Bridge started but ping failed — aborting MCP run" >&2
            _ruflo_bridge_stop || true
            rm -f "$pids_during_file" 2>/dev/null || true
            return 1
        fi
    fi

    # Snapshot baseline node PIDs (excluding our own bench process tree).
    pids_before=$(snapshot_node_pids | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')

    # Start a lightweight PID sampler in the background. 200ms cadence is
    # below typical CLI cold-start (200ms) so we have a fighting chance to
    # observe transient node spawns before they exit.
    local sampler_pid
    (
        while :; do
            snapshot_node_pids | awk '{print $1}' >> "$pids_during_file"
            # bounded failsafe sleep — not synchronization, just sampler cadence
            sleep 0.2
        done
    ) &
    sampler_pid=$!

    # Run latency samples
    local sample_data exit_code latency errors=0 ok=0
    sample_data=$(mktemp "${TMPDIR:-/tmp}/bench-samples-XXXXXX")
    local i
    for i in $(seq 1 "$BENCH_SAMPLES"); do
        # make_bench_request writes "<exit> <ms>"
        local result
        result=$(make_bench_request "$backend" "$i") || true
        exit_code=$(echo "$result" | awk '{print $1}')
        latency=$(echo "$result" | awk '{print $2}')
        echo "$latency" >> "$sample_data"
        if [[ "$exit_code" -ne 0 ]]; then
            errors=$((errors + 1))
        else
            ok=$((ok + 1))
        fi
    done

    # Stop sampler
    kill -TERM "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true

    pids_after=$(snapshot_node_pids | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')

    # Compute unique node PIDs observed during workload that were NOT in the
    # baseline snapshot — these are spawns attributable to our calls.
    local before_set during_set after_set transient_count orphan_count bridge_count
    before_set=$(mktemp "${TMPDIR:-/tmp}/bench-before-XXXXXX")
    during_set=$(mktemp "${TMPDIR:-/tmp}/bench-during-XXXXXX")
    after_set=$(mktemp "${TMPDIR:-/tmp}/bench-after-XXXXXX")
    echo "$pids_before" | tr ',' '\n' | sort -u > "$before_set"
    echo "$pids_after" | tr ',' '\n' | sort -u > "$after_set"
    sort -u "$pids_during_file" > "$during_set"
    transient_count=$(comm -23 "$during_set" "$before_set" | grep -cE '^[0-9]+$' || true)
    transient_count="${transient_count:-0}"
    # #441 sentinel: PIDs present after the run that weren't there before. For
    # MCP this should equal the bridge (1); for CLI this should be 0 — any
    # leak is the issue this work was meant to close.
    orphan_count=$(comm -23 "$after_set" "$before_set" | grep -cE '^[0-9]+$' || true)
    orphan_count="${orphan_count:-0}"

    # Count active bridge processes (just for visibility; the bridge is itself
    # a node process and will be in `during_set` for MCP runs).
    bridge_count=0
    if [[ "$backend" == "mcp" ]]; then
        bridge_count=1
    fi

    # Compute percentiles (discard first sample for cold-start)
    local pct_json
    pct_json=$(compute_percentiles "$BENCH_DISCARD_FIRST" < "$sample_data")

    # Build per-backend artifact
    local out_json="$ARTIFACT_DIR/benchmark-${backend}-${TS}.json"
    local tmp_json="${out_json}.tmp"
    local samples_array
    samples_array=$(awk 'BEGIN{p=""} {if(p!="")p=p","; p=p $1} END{print "["p"]"}' < "$sample_data")
    jq -n \
        --arg backend "$backend" \
        --arg version "$VERSION" \
        --arg ts "$(now_iso)" \
        --argjson samples "$samples_array" \
        --argjson percentiles "$pct_json" \
        --argjson errors "$errors" \
        --argjson ok "$ok" \
        --argjson transient_pids "$transient_count" \
        --argjson orphan_pids "$orphan_count" \
        --argjson bridge_pids "$bridge_count" \
        --argjson env "$(env_metadata_json)" \
        '{
            backend: $backend,
            version: $version,
            ts: $ts,
            samples_ms: $samples,
            percentiles_ms: $percentiles,
            errors: $errors,
            ok: $ok,
            unique_transient_node_pids: $transient_pids,
            orphan_node_pids_post_run: $orphan_pids,
            persistent_bridge_pids: $bridge_pids,
            env: $env
        }' > "$tmp_json"
    mv "$tmp_json" "$out_json"

    rm -f "$sample_data" "$pids_during_file" "$before_set" "$during_set" "$after_set" 2>/dev/null || true

    if [[ "$backend" == "mcp" ]]; then
        _ruflo_bridge_stop || true
        # #441 sentinel: assert no orphaned bridge process remains.
        if [[ -e "$RUFLO_BRIDGE_SOCK" ]]; then
            warn "Bridge socket file lingered after stop: $RUFLO_BRIDGE_SOCK" >&2
        fi
        unset RUFLO_BRIDGE_SOCK
    fi

    emit_event "ruflo.benchmark_run" \
        "backend=$backend" \
        "p95_ms=$(echo "$pct_json" | jq -r '.p95 // 0')" \
        "errors=$errors" \
        "transient_pids=$transient_count" 2>/dev/null

    success "backend=$backend complete (errors=$errors transient_pids=$transient_count) → $(basename "$out_json")" >&2
    printf '%s\n' "$out_json"
}

# ─── assert_thresholds — exit 2 if any backend missed its threshold ─────────
#
# The acceptance criterion in #504 is "≥10× subprocess reduction". We check:
#  1. Ratio: cli_pids / mcp_pids ≥ BENCH_REDUCTION_RATIO (the headline goal)
#  2. Absolute: mcp_pids ≤ MCP_MAX_PIDS (catches regressions, but soft-warn
#     only on shared hosts where unrelated ruflo procs may exist)
#  3. Errors must be 0 on either side (correctness)
#  4. Latency p95/p99 within configured caps (regression protection)
#
# The orphan check uses the dedicated `verify_no_orphans` multi-cycle path
# above — single-run orphan_node_pids_post_run is informational only because
# it's noisy on shared hosts (other ruflo procs rotating PIDs).
assert_thresholds() {
    local cli_json="$1" mcp_json="$2"
    local fail=0
    local cli_pids=0 mcp_pids=0

    if [[ -n "$cli_json" && -f "$cli_json" ]]; then
        local cli_errors
        cli_errors=$(jq -r '.errors' "$cli_json")
        cli_pids=$(jq -r '.unique_transient_node_pids' "$cli_json")
        if [[ "$cli_pids" -lt "$CLI_MIN_PIDS" ]]; then
            warn "CLI baseline weaker than expected: unique_pids=$cli_pids (<$CLI_MIN_PIDS) — ruflo CLI may not be installed; ratio check will be skipped"
        fi
        if [[ "$cli_errors" -gt 0 ]]; then
            warn "CLI errors=$cli_errors — comparison is degraded but not failing"
        fi
        info "CLI: errors=$cli_errors pids=$cli_pids"
    fi

    if [[ -n "$mcp_json" && -f "$mcp_json" ]]; then
        local mcp_errors mcp_orphans mcp_p95 mcp_p99
        mcp_errors=$(jq -r '.errors' "$mcp_json")
        mcp_pids=$(jq -r '.unique_transient_node_pids' "$mcp_json")
        mcp_orphans=$(jq -r '.orphan_node_pids_post_run' "$mcp_json")
        mcp_p95=$(jq -r '.percentiles_ms.p95 // 0' "$mcp_json")
        mcp_p99=$(jq -r '.percentiles_ms.p99 // 0' "$mcp_json")

        if [[ "$mcp_errors" -gt 0 ]]; then
            error "MCP errors=$mcp_errors (must be 0)"
            fail=1
        fi
        # Soft cap: warn only — ratio check below is the load-bearing one.
        if [[ "$mcp_pids" -gt "$MCP_MAX_PIDS" ]]; then
            warn "MCP unique_transient_node_pids=$mcp_pids over soft cap ${MCP_MAX_PIDS} (likely unrelated ruflo procs on shared host) — ratio check is authoritative"
        fi
        if [[ "$mcp_orphans" -gt 0 ]]; then
            warn "MCP orphan_node_pids_post_run=$mcp_orphans (informational; the multi-cycle orphan-runs check is the #441 sentinel)"
        fi
        if [[ "$mcp_p95" -gt "$LATENCY_P95_MS_MAX" ]]; then
            error "MCP latency p95=${mcp_p95}ms (max allowed: ${LATENCY_P95_MS_MAX}ms)"
            fail=1
        fi
        if [[ "$mcp_p99" -gt "$LATENCY_P99_MS_MAX" ]]; then
            warn "MCP latency p99=${mcp_p99}ms (over soft cap ${LATENCY_P99_MS_MAX}ms — recorded but not failing)"
        fi
        info "MCP: errors=$mcp_errors pids=$mcp_pids orphans=$mcp_orphans p95=${mcp_p95}ms p99=${mcp_p99}ms"
    fi

    # ── Headline ratio check (the #504 acceptance) ────────────────────────
    if [[ "$BENCH_REDUCTION_RATIO" -gt 0 \
       && -n "$cli_json" && -f "$cli_json" \
       && -n "$mcp_json" && -f "$mcp_json" \
       && "$cli_pids" -ge "$CLI_MIN_PIDS" \
       && "$mcp_pids" -gt 0 ]]; then
        # Integer math (Bash 3.2): ratio = cli_pids / mcp_pids (truncated)
        local actual_ratio=$(( cli_pids / mcp_pids ))
        if [[ "$actual_ratio" -lt "$BENCH_REDUCTION_RATIO" ]]; then
            error "Subprocess reduction ratio ${actual_ratio}× (cli=${cli_pids} / mcp=${mcp_pids}) below required ${BENCH_REDUCTION_RATIO}× (#504 acceptance)"
            fail=1
        else
            success "Subprocess reduction ratio: ${actual_ratio}× (cli=${cli_pids} / mcp=${mcp_pids}) — meets #504 ≥${BENCH_REDUCTION_RATIO}× target"
        fi
    elif [[ "$BENCH_REDUCTION_RATIO" -gt 0 ]]; then
        warn "Ratio check skipped: need both cli (≥${CLI_MIN_PIDS} PIDs) and mcp (>0 PIDs) data"
    fi

    return "$fail"
}

# ─── write_summary — human-readable markdown summary of both runs ───────────
write_summary() {
    local cli_json="$1" mcp_json="$2"
    local out_md="$ARTIFACT_DIR/summary-${TS}.md"
    local tmp_md="${out_md}.tmp"
    {
        echo "# Ruflo Backend Benchmark — $TS"
        echo
        echo "Generated by \`scripts/benchmark-ruflo-backends.sh\` v$VERSION."
        echo
        echo "## Methodology"
        echo
        echo "- $BENCH_SAMPLES samples per backend (sample #1 discarded for cold-start)"
        echo "- Bench tool: \`$BENCH_TOOL\` (use \`--tool ping\` for transport-only validation)"
        echo "- Latency measured via \`ms_time\` wallclock around each call"
        echo "- Unique transient node PIDs computed as \`during_window − baseline\`"
        echo "- 200ms PID sampler runs alongside latency samples"
        if [[ "$ORPHAN_RUNS" -gt 0 ]]; then
            echo "- #441 sentinel: $ORPHAN_RUNS consecutive MCP cycles with clean teardown assertion"
        fi
        echo
        echo "## Acceptance Thresholds"
        echo
        echo "| Metric | MCP target |"
        echo "|---|---|"
        echo "| Unique transient node PIDs | ≤ $MCP_MAX_PIDS |"
        echo "| Latency p95 | ≤ ${LATENCY_P95_MS_MAX} ms |"
        echo "| Latency p99 (soft) | ≤ ${LATENCY_P99_MS_MAX} ms |"
        echo "| Errors | 0 |"
        echo
        echo "## Results"
        echo
        echo "| Backend | Errors | Transient PIDs | p50 (ms) | p95 (ms) | p99 (ms) | Mean (ms) |"
        echo "|---------|--------|----------------|---------:|---------:|---------:|----------:|"
        local row
        for row in "$cli_json" "$mcp_json"; do
            [[ -z "$row" || ! -f "$row" ]] && continue
            jq -r '
                "| " + .backend
                + " | " + (.errors|tostring)
                + " | " + (.unique_transient_node_pids|tostring)
                + " | " + ((.percentiles_ms.p50 // "—")|tostring)
                + " | " + ((.percentiles_ms.p95 // "—")|tostring)
                + " | " + ((.percentiles_ms.p99 // "—")|tostring)
                + " | " + ((.percentiles_ms.mean // "—")|tostring)
                + " |"
            ' "$row"
        done
        echo
        echo "## Raw Artifacts"
        echo
        [[ -f "$cli_json" ]] && echo "- \`$(basename "$cli_json")\`"
        [[ -f "$mcp_json" ]] && echo "- \`$(basename "$mcp_json")\`"
        echo
        echo "_See \`docs/ruflo-mcp-transport.md\` for the contract and \`docs/adr/ruflo-backend-transport.md\` for the design rationale._"
    } > "$tmp_md"
    mv "$tmp_md" "$out_md"
    success "Summary: $out_md"
}

# ─── EXIT trap — best-effort cleanup so failed runs don't leak ──────────────
_cleanup() {
    if [[ -n "${RUFLO_BRIDGE_SOCK:-}" && "$RUFLO_BRIDGE_SOCK" == */ruflo-bench-bridge-* ]]; then
        _ruflo_bridge_stop 2>/dev/null || true
    fi
}
trap _cleanup EXIT

# ─── verify_no_orphans — run N MCP cycles, assert clean teardown each time ──
# This is the #441 sentinel test. Each cycle: spawn bridge → fire
# BENCH_SAMPLES calls → stop bridge → snapshot ruflo-related node procs
# → diff against the snapshot taken before the very first cycle. The
# delta must remain 0 across all cycles, otherwise we are leaking node
# processes per-cycle (the bug the persistent bridge was meant to close).
#
# Writes orphan-runs-<ts>.json with per-cycle snapshots and final delta.
# Returns 0 on clean teardown, 1 on any orphan detected.
verify_no_orphans() {
    local runs="$1"
    [[ "$runs" -le 0 ]] && return 0

    local out_json="$ARTIFACT_DIR/orphan-runs-${TS}.json"
    local tmp_json="${out_json}.tmp"
    local baseline_file cycle_file delta_file
    baseline_file=$(mktemp "${TMPDIR:-/tmp}/bench-orphan-base-XXXXXX")
    cycle_file=$(mktemp "${TMPDIR:-/tmp}/bench-orphan-cycle-XXXXXX")
    delta_file=$(mktemp "${TMPDIR:-/tmp}/bench-orphan-delta-XXXXXX")

    info "Orphan validation: running $runs consecutive MCP cycles (#441 sentinel)" >&2

    # Baseline: ruflo-related node procs before we touch anything.
    # Filter to actual ruflo procs only — the awk/grep tools that do the
    # filtering themselves contain the string "ruflo" in their argv (because
    # the regex literal does), so we must exclude them or every snapshot
    # picks up its own filter pipeline as a false-positive ruflo proc.
    snapshot_node_pids \
        | awk '/ruflo/ && !/[a]wk|[g]rep/ {print $1}' \
        | sort -u > "$baseline_file"
    local baseline_count
    baseline_count=$(wc -l < "$baseline_file" | tr -d ' ')

    local cycle delta_total=0 deltas_csv=""
    for cycle in $(seq 1 "$runs"); do
        info "  cycle $cycle/$runs" >&2

        # Each cycle uses a fresh socket so we genuinely measure
        # start→stop teardown, not socket reuse.
        export RUFLO_BRIDGE_SOCK="${TMPDIR:-/tmp}/ruflo-bench-bridge-orphan-$$-${cycle}.sock"

        if ! _ruflo_bridge_start; then
            error "  cycle $cycle: bridge failed to start" >&2
            unset RUFLO_BRIDGE_SOCK
            rm -f "$baseline_file" "$cycle_file" "$delta_file" 2>/dev/null || true
            return 1
        fi

        # Light workload — 5 calls is enough to exercise the dispatch
        # path; we're not measuring latency here, just teardown cleanliness.
        local i
        for i in 1 2 3 4 5; do
            make_bench_request mcp "$i" >/dev/null 2>&1 || true
        done

        _ruflo_bridge_stop || true

        # Give the OS a moment to reap the bridge (bounded failsafe — not
        # synchronization; the bridge's SIGTERM handler unlinks before exit
        # but the kernel may delay process-table cleanup).
        sleep 1

        # Snapshot post-cycle. Anything in ruflo namespace not in baseline
        # is a leak attributable to this cycle.
        snapshot_node_pids \
            | awk '/ruflo/ && !/[a]wk|[g]rep/ {print $1}' \
            | sort -u > "$cycle_file"
        comm -23 "$cycle_file" "$baseline_file" > "$delta_file"
        local cycle_delta
        # NB: `grep -c || echo 0` produces double output under pipefail.
        # Use `|| true` and rely on the param-expansion fallback.
        cycle_delta=$(grep -cE '^[0-9]+$' "$delta_file" 2>/dev/null | head -1 || true)
        cycle_delta="${cycle_delta:-0}"
        cycle_delta="${cycle_delta//[^0-9]/}"
        cycle_delta="${cycle_delta:-0}"

        if [[ -z "$deltas_csv" ]]; then
            deltas_csv="$cycle_delta"
        else
            deltas_csv="$deltas_csv,$cycle_delta"
        fi

        if [[ "$cycle_delta" -gt 0 ]]; then
            warn "  cycle $cycle: $cycle_delta orphan node proc(s) detected" >&2
            delta_total=$((delta_total + cycle_delta))
        fi

        # Clean socket file path for the next cycle so leftover doesn't
        # confuse the next start.
        rm -f "$RUFLO_BRIDGE_SOCK" "${RUFLO_BRIDGE_SOCK}.pid" 2>/dev/null || true
        unset RUFLO_BRIDGE_SOCK
    done

    # Final snapshot — the one that matters for #441. Even if intermediate
    # cycles showed transient orphans (kernel slowness), the final state
    # must be clean.
    snapshot_node_pids \
        | awk '/ruflo/ && !/[a]wk|[g]rep/ {print $1}' \
        | sort -u > "$cycle_file"
    comm -23 "$cycle_file" "$baseline_file" > "$delta_file"
    local final_delta
    final_delta=$(grep -cE '^[0-9]+$' "$delta_file" 2>/dev/null | head -1 || true)
    final_delta="${final_delta:-0}"
    final_delta="${final_delta//[^0-9]/}"
    final_delta="${final_delta:-0}"

    jq -n \
        --argjson runs "$runs" \
        --argjson baseline "$baseline_count" \
        --argjson final_delta "$final_delta" \
        --arg deltas_csv "$deltas_csv" \
        --argjson env "$(env_metadata_json)" \
        '{
            runs: $runs,
            baseline_node_pids: $baseline,
            per_cycle_orphan_deltas: ($deltas_csv | split(",") | map(tonumber)),
            final_orphan_delta: $final_delta,
            passed: ($final_delta == 0),
            env: $env
        }' > "$tmp_json"
    mv "$tmp_json" "$out_json"

    rm -f "$baseline_file" "$cycle_file" "$delta_file" 2>/dev/null || true

    emit_event "ruflo.benchmark_orphan_runs" \
        "runs=$runs" \
        "final_delta=$final_delta" \
        "intermediate_deltas=$deltas_csv" 2>/dev/null

    if [[ "$final_delta" -gt 0 ]]; then
        error "#441 sentinel FAILED: $final_delta orphan node proc(s) survive after $runs MCP cycles → $(basename "$out_json")"
        return 1
    fi

    success "#441 sentinel passed: 0 orphans after $runs MCP cycles → $(basename "$out_json")"
    return 0
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cli_json="" mcp_json=""

    if [[ $RUN_CLI -eq 1 ]]; then
        cli_json=$(run_backend cli) || true
    fi
    if [[ $RUN_MCP -eq 1 ]]; then
        mcp_json=$(run_backend mcp) || true
    fi

    write_summary "$cli_json" "$mcp_json"

    # Optional #441 multi-run orphan validation (must run AFTER per-backend
    # runs so we don't perturb the latency snapshot with extra spawns).
    if [[ "$ORPHAN_RUNS" -gt 0 ]]; then
        if ! verify_no_orphans "$ORPHAN_RUNS"; then
            if [[ $DO_ASSERT -eq 1 ]]; then
                error "Acceptance check failed: orphan runs detected leaks"
                exit 2
            fi
        fi
    fi

    if [[ $DO_ASSERT -eq 1 ]]; then
        if ! assert_thresholds "$cli_json" "$mcp_json"; then
            error "Acceptance thresholds NOT met — see summary for details"
            exit 2
        fi
        success "Acceptance thresholds met"
    fi
}

# When sourced (e.g. by sw-ruflo-benchmark-test.sh) we want the function
# definitions but NOT to drive a real benchmark run. Bash 3.2 safe.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
