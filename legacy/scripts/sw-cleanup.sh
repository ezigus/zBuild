#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-cleanup.sh — Clean up orphaned Claude team sessions & artifacts     ║
# ║                                                                          ║
# ║  Default: dry-run (shows what would be cleaned).                         ║
# ║  Use --force to actually kill sessions and remove files.                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.6.1"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# ─── Parse Args ──────────────────────────────────────────────────────────────

FORCE=false
PRUNE_ORPHANS=false
TEST_ORPHANS=false
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        --prune-orphans) PRUNE_ORPHANS=true ;;
        --test-orphans) TEST_ORPHANS=true ;;
        --help|-h)
            echo -e "${CYAN}${BOLD}shipwright cleanup${RESET} — Clean up orphaned sessions and artifacts"
            echo ""
            echo -e "${BOLD}USAGE${RESET}"
            echo -e "  shipwright cleanup                    ${DIM}# Dry-run: show what would be cleaned${RESET}"
            echo -e "  shipwright cleanup --force            ${DIM}# Actually kill sessions and remove files${RESET}"
            echo -e "  shipwright cleanup --prune-orphans    ${DIM}# Kill orphaned pipeline processes${RESET}"
            echo -e "  shipwright cleanup --test-orphans     ${DIM}# Kill orphaned test harness processes${RESET}"
            exit 0
            ;;
        *)
            error "Unknown option: ${arg}"
            exit 1
            ;;
    esac
done

# ─── --prune-orphans: Kill stale pipeline processes ─────────────────────────

# Helper: returns true if pid is orphaned (parent dead or reparented to init/1)
_is_orphan() {
    local pid="$1"
    local ppid
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    # Reparented to init (PID 1) — genuine orphan
    [[ "$ppid" == "1" ]] && return 0
    # Parent no longer alive — orphan
    kill -0 "$ppid" 2>/dev/null || return 0
    # Parent alive — not an orphan
    return 1
}

if $PRUNE_ORPHANS; then
    echo ""
    echo -e "${BOLD}Pruning Orphaned Pipeline Processes${RESET}"
    echo -e "${DIM}────────────────────────────────────────${RESET}"

    orphans_found=0
    orphans_killed=0

    _kill_orphan() {
        local pid="$1" label="$2"
        # Only kill if genuinely orphaned (parent dead or reparented to init)
        if ! _is_orphan "$pid"; then
            echo -e "  ${DIM}Skipping PID ${pid} (${label}) — parent is alive${RESET}"
            return 0
        fi
        orphans_found=$((orphans_found + 1))
        echo -e "  ${YELLOW}○${RESET} Orphan: PID ${pid} (${label}) $(ps -p "$pid" -o comm= 2>/dev/null || true)"
        # Only send group kill if pid is its own group leader
        local pgid
        pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || true
        if [[ "${pgid:-}" == "$pid" ]]; then
            kill -- -"$pid" 2>/dev/null || true
        fi
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        orphans_killed=$((orphans_killed + 1))
    }

    while IFS= read -r pid; do
        [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        _kill_orphan "$pid" "sw-pipeline.sh"
    done < <(pgrep -f "sw-pipeline.sh" 2>/dev/null || true)

    while IFS= read -r pid; do
        [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        _kill_orphan "$pid" "sw-loop.sh"
    done < <(pgrep -f "sw-loop.sh" 2>/dev/null || true)

    # Orphaned claude -p processes (prompt-mode only — never interactive sessions)
    # Trailing space in pattern avoids matching args like --claude -parallel
    while IFS= read -r pid; do
        [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        _kill_orphan "$pid" "claude -p (orphaned)"
    done < <(pgrep -f "claude -p " 2>/dev/null || true)

    # Orphaned timeout wrappers around claude (spawned by TIMEOUT_CMD in loop/pipeline)
    while IFS= read -r pid; do
        [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        _kill_orphan "$pid" "timeout.*claude (orphaned)"
    done < <(pgrep -f "timeout.*claude" 2>/dev/null || true)

    if [[ "$orphans_found" -eq 0 ]]; then
        success "No orphaned pipeline processes found."
    else
        success "Sent kill signal to ${orphans_killed} orphaned process(es)."
    fi
    echo ""
    exit 0
fi

# ─── --test-orphans: Kill stale test harness processes ──────────────────────

if $TEST_ORPHANS; then
    echo ""
    echo -e "${BOLD}Pruning Orphaned Test Harness Processes${RESET}"
    echo -e "${DIM}────────────────────────────────────────${RESET}"

    test_orphans_found=0
    test_orphans_killed=0

    while IFS= read -r pid; do
        [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        if ! _is_orphan "$pid"; then
            echo -e "  ${DIM}Skipping PID ${pid} (sw-*-test.sh) — parent is alive${RESET}"
            continue
        fi
        test_orphans_found=$((test_orphans_found + 1))
        local_comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        echo -e "  ${YELLOW}○${RESET} Orphan: PID ${pid} (sw-*-test.sh) ${local_comm}"
        pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || true
        if [[ "${pgid:-}" == "$pid" ]]; then
            kill -- -"$pid" 2>/dev/null || true
        fi
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        test_orphans_killed=$((test_orphans_killed + 1))
    done < <(pgrep -f "sw-[a-z].*-test\.sh" 2>/dev/null || true)

    if [[ "$test_orphans_found" -eq 0 ]]; then
        success "No orphaned test processes found."
    else
        success "Sent kill signal to ${test_orphans_killed} orphaned test process(es)."
    fi
    echo ""
    exit 0
fi

# ─── Track cleanup stats ────────────────────────────────────────────────────

WINDOWS_FOUND=0
WINDOWS_KILLED=0
TEAM_DIRS_FOUND=0
TEAM_DIRS_REMOVED=0
TASK_DIRS_FOUND=0
TASK_DIRS_REMOVED=0
ARTIFACTS_FOUND=0
ARTIFACTS_REMOVED=0
CHECKPOINTS_FOUND=0
CHECKPOINTS_REMOVED=0
HEARTBEATS_FOUND=0
HEARTBEATS_REMOVED=0
BRANCHES_FOUND=0
BRANCHES_REMOVED=0
STATE_RESET=0
SWARM_SESSIONS_FOUND=0
SWARM_SESSIONS_KILLED=0
SWARM_REGISTRY_REMOVED=0

# ─── 1. Find orphaned tmux windows ──────────────────────────────────────────

echo ""
if $FORCE; then
    info "Cleaning up Claude team sessions ${RED}${BOLD}(FORCE MODE)${RESET}"
else
    info "Scanning for orphaned Claude team sessions ${DIM}(dry-run)${RESET}"
fi
echo ""

echo -e "${BOLD}Tmux Windows${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

# Look for windows with "claude" in the name across all sessions
CLAUDE_WINDOWS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && CLAUDE_WINDOWS+=("$line")
done < <(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null | grep -i "claude" || true)

if [[ ${#CLAUDE_WINDOWS[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No Claude team windows found.${RESET}"
else
    for win in "${CLAUDE_WINDOWS[@]}"; do
        WINDOWS_FOUND=$((WINDOWS_FOUND + 1))
        local_target="$(echo "$win" | cut -d' ' -f1)"
        local_name="$(echo "$win" | cut -d' ' -f2-)"

        if $FORCE; then
            tmux kill-window -t "$local_target" 2>/dev/null && {
                echo -e "  ${RED}✗${RESET} Killed: ${local_name} ${DIM}(${local_target})${RESET}"
                WINDOWS_KILLED=$((WINDOWS_KILLED + 1))
            } || {
                warn "  Could not kill: ${local_name} (${local_target})"
            }
        else
            echo -e "  ${YELLOW}○${RESET} Would kill: ${local_name} ${DIM}(${local_target})${RESET}"
        fi
    done
fi

# ─── 1b. Swarm sessions and registry ────────────────────────────────────────

echo ""
echo -e "${BOLD}Swarm Sessions${RESET}  ${DIM}swarm-* tmux sessions${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

SWARM_REGISTRY="${HOME}/.shipwright/swarm/registry.json"

# Find all swarm-* tmux sessions
SWARM_SESSIONS=()
while IFS= read -r sess; do
    [[ -n "$sess" ]] && SWARM_SESSIONS+=("$sess")
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^swarm-' || true)

if [[ ${#SWARM_SESSIONS[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No swarm sessions found.${RESET}"
else
    for sess in "${SWARM_SESSIONS[@]}"; do
        SWARM_SESSIONS_FOUND=$((SWARM_SESSIONS_FOUND + 1))
        if $FORCE; then
            tmux kill-session -t "$sess" 2>/dev/null && {
                echo -e "  ${RED}✗${RESET} Killed swarm session: ${sess}"
                SWARM_SESSIONS_KILLED=$((SWARM_SESSIONS_KILLED + 1))
            } || warn "  Could not kill swarm session: ${sess}"
        else
            echo -e "  ${YELLOW}○${RESET} Would kill: ${sess}"
        fi
    done
fi

# Clean stale registry entries (agents with no live tmux session)
if [[ -f "$SWARM_REGISTRY" ]]; then
    swarm_reg_count=$(jq -r '.agents | length' "$SWARM_REGISTRY" 2>/dev/null || echo "0")

    if [[ "${swarm_reg_count:-0}" -gt 0 ]]; then
        # Find agents whose tmux session is gone
        swarm_stale_ids=""
        while IFS= read -r line; do
            sw_agent=$(echo "$line" | base64 -d 2>/dev/null || echo "$line")
            sw_aid=$(echo "$sw_agent" | jq -r '.id')
            sw_sess="swarm-${sw_aid}"
            if ! tmux has-session -t "$sw_sess" 2>/dev/null; then
                swarm_stale_ids="${swarm_stale_ids} ${sw_aid}"
                SWARM_REGISTRY_REMOVED=$((SWARM_REGISTRY_REMOVED + 1))
                if $FORCE; then
                    echo -e "  ${RED}✗${RESET} Removed orphaned registry entry: ${sw_aid}"
                else
                    echo -e "  ${YELLOW}○${RESET} Would remove orphaned registry entry: ${sw_aid}"
                fi
            fi
        done < <(jq -r '.agents[] | @base64' "$SWARM_REGISTRY" 2>/dev/null || true)

        if $FORCE && [[ -n "$swarm_stale_ids" ]]; then
            swarm_tmp=$(mktemp "${TMPDIR:-/tmp}/sw-swarm-registry.XXXXXX")
            # Build JSON array of stale IDs for --argjson
            swarm_stale_json="["
            swarm_first=true
            for swarm_sid in $swarm_stale_ids; do
                [[ -z "$swarm_sid" ]] && continue
                $swarm_first || swarm_stale_json="${swarm_stale_json},"
                swarm_stale_json="${swarm_stale_json}\"${swarm_sid}\""
                swarm_first=false
            done
            swarm_stale_json="${swarm_stale_json}]"
            jq --argjson stale "$swarm_stale_json" \
               '.agents |= map(select(.id as $id | ($stale | index($id)) == null)) | .active_count = ([.agents[] | select(.status == "active")] | length) | .last_updated = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
               "$SWARM_REGISTRY" > "$swarm_tmp" && [[ -s "$swarm_tmp" ]] && \
            mv "$swarm_tmp" "$SWARM_REGISTRY" || rm -f "$swarm_tmp"
        fi

        if [[ "$SWARM_REGISTRY_REMOVED" -eq 0 ]]; then
            echo -e "  ${DIM}No orphaned registry entries.${RESET}"
        fi
    else
        echo -e "  ${DIM}Swarm registry is empty.${RESET}"
    fi
else
    echo -e "  ${DIM}No swarm registry found.${RESET}"
fi

# ─── 2. Clean up ~/.claude/teams/ ───────────────────────────────────────────

echo ""
echo -e "${BOLD}Team Configs${RESET}  ${DIM}~/.claude/teams/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

TEAMS_DIR="${HOME}/.claude/teams"
if [[ -d "$TEAMS_DIR" ]]; then
    while IFS= read -r team_dir; do
        [[ -z "$team_dir" ]] && continue
        TEAM_DIRS_FOUND=$((TEAM_DIRS_FOUND + 1))
        team_name="$(basename "$team_dir")"

        if $FORCE; then
            rm -rf "$team_dir" && {
                echo -e "  ${RED}✗${RESET} Removed: ${team_name}/"
                TEAM_DIRS_REMOVED=$((TEAM_DIRS_REMOVED + 1))
            }
        else
            # Count files inside
            file_count=$(find "$team_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            echo -e "  ${YELLOW}○${RESET} Would remove: ${team_name}/ ${DIM}(${file_count} files)${RESET}"
        fi
    done < <(find "$TEAMS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
else
    echo -e "  ${DIM}No team configs found.${RESET}"
fi

# ─── 3. Clean up ~/.claude/tasks/ ───────────────────────────────────────────

echo ""
echo -e "${BOLD}Task Lists${RESET}  ${DIM}~/.claude/tasks/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

TASKS_DIR="${HOME}/.claude/tasks"
if [[ -d "$TASKS_DIR" ]]; then
    while IFS= read -r task_dir; do
        [[ -z "$task_dir" ]] && continue
        TASK_DIRS_FOUND=$((TASK_DIRS_FOUND + 1))
        task_name="$(basename "$task_dir")"

        if $FORCE; then
            rm -rf "$task_dir" && {
                echo -e "  ${RED}✗${RESET} Removed: ${task_name}/"
                TASK_DIRS_REMOVED=$((TASK_DIRS_REMOVED + 1))
            }
        else
            task_count=$(find "$task_dir" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
            echo -e "  ${YELLOW}○${RESET} Would remove: ${task_name}/ ${DIM}(${task_count} tasks)${RESET}"
        fi
    done < <(find "$TASKS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
else
    echo -e "  ${DIM}No task directories found.${RESET}"
fi

# ─── 4. Pipeline Artifacts ──────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Pipeline Artifacts${RESET}  ${DIM}.claude/pipeline-artifacts/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

PIPELINE_ARTIFACTS="$PROJECT_ROOT/.claude/pipeline-artifacts"
if [[ -d "$PIPELINE_ARTIFACTS" ]]; then
    artifact_file_count=$(find "$PIPELINE_ARTIFACTS" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${artifact_file_count:-0}" -gt 0 ]]; then
        ARTIFACTS_FOUND=$((artifact_file_count))

        # Calculate total size
        artifact_size=$(du -sh "$PIPELINE_ARTIFACTS" 2>/dev/null | cut -f1 || echo "unknown")

        if $FORCE; then
            rm -rf "$PIPELINE_ARTIFACTS"
            mkdir -p "$PIPELINE_ARTIFACTS"
            ARTIFACTS_REMOVED=$((artifact_file_count))
            echo -e "  ${RED}✗${RESET} Cleaned ${artifact_file_count} files (${artifact_size})"
        else
            echo -e "  ${YELLOW}○${RESET} Would clean: ${artifact_file_count} files (${artifact_size})"
        fi
    else
        echo -e "  ${DIM}No pipeline artifacts found.${RESET}"
    fi
else
    echo -e "  ${DIM}No pipeline artifacts directory.${RESET}"
fi

# ─── 5. Checkpoints ────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Checkpoints${RESET}  ${DIM}.claude/pipeline-artifacts/checkpoints/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

CHECKPOINT_DIR="$PROJECT_ROOT/.claude/pipeline-artifacts/checkpoints"
if [[ -d "$CHECKPOINT_DIR" ]]; then
    cp_file_count=0
    for cp_file in "${CHECKPOINT_DIR}"/*-checkpoint.json; do
        [[ -f "$cp_file" ]] || continue
        cp_file_count=$((cp_file_count + 1))
    done

    if [[ "$cp_file_count" -gt 0 ]]; then
        CHECKPOINTS_FOUND=$cp_file_count

        if $FORCE; then
            rm -f "${CHECKPOINT_DIR}"/*-checkpoint.json
            CHECKPOINTS_REMOVED=$cp_file_count
            echo -e "  ${RED}✗${RESET} Removed ${cp_file_count} checkpoint(s)"
        else
            echo -e "  ${YELLOW}○${RESET} Would remove: ${cp_file_count} checkpoint(s)"
        fi
    else
        echo -e "  ${DIM}No checkpoints found.${RESET}"
    fi
else
    echo -e "  ${DIM}No checkpoint directory.${RESET}"
fi

# ─── 6. Pipeline State ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Pipeline State${RESET}  ${DIM}.claude/pipeline-state.md${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

PIPELINE_STATE="$PROJECT_ROOT/.claude/pipeline-state.md"
if [[ -f "$PIPELINE_STATE" ]]; then
    state_status=$(sed -n 's/^status: *//p' "$PIPELINE_STATE" | head -1 || true)
    state_issue=$(sed -n 's/^issue: *//p' "$PIPELINE_STATE" | head -1 || true)

    case "${state_status:-}" in
        complete|failed|idle|"")
            if $FORCE; then
                rm -f "$PIPELINE_STATE"
                STATE_RESET=1
                echo -e "  ${RED}✗${RESET} Removed stale state (was: ${state_status:-empty}${state_issue:+, issue #$state_issue})"
            else
                echo -e "  ${YELLOW}○${RESET} Would remove: status=${state_status:-empty}${state_issue:+, issue #$state_issue}"
            fi
            ;;
        running|paused|interrupted)
            echo -e "  ${CYAN}●${RESET} Active pipeline: status=${state_status}${state_issue:+, issue #$state_issue} ${DIM}(skipping)${RESET}"
            ;;
        *)
            echo -e "  ${DIM}Unknown state: ${state_status}${RESET}"
            ;;
    esac
else
    echo -e "  ${DIM}No pipeline state file.${RESET}"
fi

# ─── 7. Stale Heartbeats ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Heartbeats${RESET}  ${DIM}~/.shipwright/heartbeats/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

HEARTBEAT_DIR="${HOME}/.shipwright/heartbeats"
if [[ -d "$HEARTBEAT_DIR" ]]; then
    now_e=$(date +%s)
    stale_threshold=$(_config_get_int "cleanup.heartbeat_stale_seconds" 3600)

    while IFS= read -r hb_file; do
        [[ -f "$hb_file" ]] || continue
        hb_mtime=$(file_mtime "$hb_file")
        if [[ $((now_e - hb_mtime)) -gt $stale_threshold ]]; then
            HEARTBEATS_FOUND=$((HEARTBEATS_FOUND + 1))
            hb_name=$(basename "$hb_file" .json)

            if $FORCE; then
                rm -f "$hb_file"
                HEARTBEATS_REMOVED=$((HEARTBEATS_REMOVED + 1))
                echo -e "  ${RED}✗${RESET} Removed: ${hb_name} ${DIM}(stale >1h)${RESET}"
            else
                age_min=$(( (now_e - hb_mtime) / 60 ))
                echo -e "  ${YELLOW}○${RESET} Would remove: ${hb_name} ${DIM}(${age_min}m old)${RESET}"
            fi
        fi
    done < <(find "$HEARTBEAT_DIR" -name '*.json' -type f 2>/dev/null)

    if [[ "$HEARTBEATS_FOUND" -eq 0 ]]; then
        echo -e "  ${DIM}No stale heartbeats.${RESET}"
    fi
else
    echo -e "  ${DIM}No heartbeat directory.${RESET}"
fi

# ─── 8. Orphaned pipeline/* branches ───────────────────────────────────────

echo ""
echo -e "${BOLD}Orphaned Branches${RESET}  ${DIM}pipeline/* and daemon/*${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Collect active worktree paths
    active_worktrees=""
    while IFS= read -r wt_line; do
        active_worktrees="${active_worktrees} ${wt_line}"
    done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //')

    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        branch="${branch## }"  # trim leading spaces
        # Check if this branch has an active worktree
        has_worktree=false
        for wt in $active_worktrees; do
            if echo "$wt" | grep -q "${branch##*/}" 2>/dev/null; then
                has_worktree=true
                break
            fi
        done

        if [[ "$has_worktree" == "false" ]]; then
            BRANCHES_FOUND=$((BRANCHES_FOUND + 1))
            if $FORCE; then
                git branch -D "$branch" 2>/dev/null || true
                BRANCHES_REMOVED=$((BRANCHES_REMOVED + 1))
                echo -e "  ${RED}✗${RESET} Deleted: ${branch}"
            else
                echo -e "  ${YELLOW}○${RESET} Would delete: ${branch}"
            fi
        fi
    done < <(git branch --list 'pipeline/*' --list 'daemon/*' 2>/dev/null)

    if [[ "$BRANCHES_FOUND" -eq 0 ]]; then
        echo -e "  ${DIM}No orphaned branches.${RESET}"
    fi
else
    echo -e "  ${DIM}Not in a git repository.${RESET}"
fi

# ─── 9. Corrupted State Backups ────────────────────────────────────────────

echo ""
echo -e "${BOLD}Corrupted State Backups${RESET}  ${DIM}~/.shipwright/daemon-state.json.corrupted.*${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

CORRUPTED_STATE_FILE="$HOME/.shipwright/daemon-state.json"
CORRUPTED_FOUND=0
CORRUPTED_REMOVED=0
# Use find to avoid "Argument list too long" when thousands of backups exist.
corrupted_count=$(find "$(dirname "$CORRUPTED_STATE_FILE")" -maxdepth 1 -type f \
    -name "$(basename "$CORRUPTED_STATE_FILE").corrupted.*" -print 2>/dev/null | wc -l | tr -d ' ')
corrupted_count=${corrupted_count:-0}
CORRUPTED_FOUND=$corrupted_count
if [[ $corrupted_count -gt 5 ]]; then
    if $FORCE; then
        find "$(dirname "$CORRUPTED_STATE_FILE")" -maxdepth 1 -type f \
            -name "$(basename "$CORRUPTED_STATE_FILE").corrupted.*" -print 2>/dev/null \
            | sort -r | tail -n +6 \
            | while IFS= read -r _cf; do rm -f "$_cf" 2>/dev/null || true; done
        CORRUPTED_REMOVED=$((corrupted_count - 5))
        echo -e "  ${RED}✗${RESET} Pruned corrupted state backups ${DIM}(kept 5 of ${corrupted_count})${RESET}"
    else
        echo -e "  ${YELLOW}○${RESET} Would prune corrupted state backups ${DIM}(${corrupted_count} found, would keep 5)${RESET}"
    fi
elif [[ $corrupted_count -gt 0 ]]; then
    echo -e "  ${DIM}${corrupted_count} corrupted backup(s) — within limit (≤5).${RESET}"
else
    echo -e "  ${DIM}No corrupted state backups.${RESET}"
fi

# ─── 10. Pipeline Task Files ───────────────────────────────────────────────

echo ""
echo -e "${BOLD}Pipeline Task Files${RESET}  ${DIM}pipeline-tasks*.md (>1 day old)${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

PIPELINE_TASKS_FOUND=0
PIPELINE_TASKS_REMOVED=0
while IFS= read -r pt_file; do
    [[ -f "$pt_file" ]] || continue
    PIPELINE_TASKS_FOUND=$((PIPELINE_TASKS_FOUND + 1))
    pt_name=$(basename "$pt_file")
    if $FORCE; then
        rm -f "$pt_file"
        PIPELINE_TASKS_REMOVED=$((PIPELINE_TASKS_REMOVED + 1))
        echo -e "  ${RED}✗${RESET} Removed: ${pt_name}"
    else
        echo -e "  ${YELLOW}○${RESET} Would remove: ${pt_name}"
    fi
done < <(find "$PROJECT_ROOT/.claude" -maxdepth 1 -name "pipeline-tasks*.md" -mtime +1 -type f 2>/dev/null)

if [[ "$PIPELINE_TASKS_FOUND" -eq 0 ]]; then
    echo -e "  ${DIM}No stale pipeline task files.${RESET}"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${DIM}────────────────────────────────────────${RESET}"

TOTAL_FOUND=$((WINDOWS_FOUND + SWARM_SESSIONS_FOUND + SWARM_REGISTRY_REMOVED + TEAM_DIRS_FOUND + TASK_DIRS_FOUND + ARTIFACTS_FOUND + CHECKPOINTS_FOUND + HEARTBEATS_FOUND + BRANCHES_FOUND + STATE_RESET + CORRUPTED_FOUND + PIPELINE_TASKS_FOUND))

if $FORCE; then
    TOTAL_CLEANED=$((WINDOWS_KILLED + SWARM_SESSIONS_KILLED + SWARM_REGISTRY_REMOVED + TEAM_DIRS_REMOVED + TASK_DIRS_REMOVED + ARTIFACTS_REMOVED + CHECKPOINTS_REMOVED + HEARTBEATS_REMOVED + BRANCHES_REMOVED + STATE_RESET + CORRUPTED_REMOVED + PIPELINE_TASKS_REMOVED))
    if [[ $TOTAL_CLEANED -gt 0 ]]; then
        success "Cleaned ${TOTAL_CLEANED} items"
        echo -e "  ${DIM}windows: ${WINDOWS_KILLED}, swarm sessions: ${SWARM_SESSIONS_KILLED}, swarm registry: ${SWARM_REGISTRY_REMOVED}${RESET}"
        echo -e "  ${DIM}teams: ${TEAM_DIRS_REMOVED}, tasks: ${TASK_DIRS_REMOVED}, artifacts: ${ARTIFACTS_REMOVED}${RESET}"
        echo -e "  ${DIM}checkpoints: ${CHECKPOINTS_REMOVED}, heartbeats: ${HEARTBEATS_REMOVED}, branches: ${BRANCHES_REMOVED}, state: ${STATE_RESET}${RESET}"
        echo -e "  ${DIM}corrupted backups pruned: ${CORRUPTED_REMOVED}, pipeline task files: ${PIPELINE_TASKS_REMOVED}${RESET}"
    else
        success "Nothing to clean up."
    fi
else
    if [[ $TOTAL_FOUND -gt 0 ]]; then
        warn "Found ${TOTAL_FOUND} items to clean. Run with ${BOLD}--force${RESET} to remove them:"
        echo -e "  ${DIM}shipwright cleanup --force${RESET}"
    else
        success "Everything is clean. No orphaned sessions or artifacts found."
    fi
fi
echo ""
