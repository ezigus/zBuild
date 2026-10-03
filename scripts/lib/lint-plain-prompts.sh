#!/usr/bin/env bash
# scripts/lib/lint-plain-prompts.sh — #2269 (ADR-067)
#
# Model-facing text speaks plainly. Engine-internal words leak into the text
# sent to models and are read in their everyday sense: in #2032 run 37066151065
# design listed an event-name list as "WIRING", the gate fed back "WIRING …
# inert", and test-author satisfied the measure with a test that greps the file.
#
# This lint reads what a model receives, from the files listed in
# config/model-facing-sources.txt:
#   - heredoc bodies (prompts);
#   - `stage_summary_write` calls and their continuation lines (a stage summary
#     is read by every later stage — ADR-055 §9);
#   - `clauses+=(` lines (the acceptance gate builds its feedback from them);
#   - for a file listed with the word `printf` after it, every printf line (the
#     prompt blocks built that way: checkpoint, budget note, repo rules);
#   - whole .md prompt files.
# Logging (error/warn/info), events and jq programs are not model-facing.
# It refuses engine-internal vocabulary and maintainer notes:
#   - internal check names: NEGCTL, REACHABILITY, inert, tautolog*, WIRING_MISSING,
#     UNCLASSIFIED, GUARD_REGRESSED, "negative control";
#   - maintainer notes and internals: ADR-<n>, _TPL_*.
# Parser keys the engine reads back (WIRING:, TESTFILES:, LOOP_COMPLETE, BLOCKED:)
# are allowed: the plain question sits beside them in the prompt.
#
# A heredoc that is not model-facing (a jq program, a JSON template) is exempted
# by `# not-model-facing` on its opening line.
#
# Usage: bash scripts/lib/lint-plain-prompts.sh [repo_root]
# Exit:  0 = clean; 1 = a forbidden word in model-facing text, or a listed file is missing.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LIST="$ROOT/config/model-facing-sources.txt"
[[ -f "$LIST" ]] || { echo "lint-plain-prompts: no $LIST" >&2; exit 1; }

# One extended regex; matched case-sensitively except where noted in the class.
FORBIDDEN='NEGCTL|REACHABILITY|[Ii]nert|[Tt]autolog|WIRING_MISSING|UNCLASSIFIED|GUARD_REGRESSED|[Nn]egative control|ADR-[0-9]+|_TPL_[A-Z]'

bad=0 files=0
# A model sees a variable's VALUE, never its name: strip $name / ${…} first.
_check() {   # _check <file> <lineno> <line>
    local _s="$3"
    while [[ "$_s" =~ (\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*) ]]; do
        _s="${_s/"${BASH_REMATCH[1]}"/}"
    done
    [[ "$_s" =~ $FORBIDDEN ]] && _report "$1" "$2" "$_s"
    return 0
}
_report() {   # _report <file> <lineno> <line>
    local hit; hit="$(grep -oE "$FORBIDDEN" <<< "$3" | tr '\n' ' ')"
    echo "lint-plain-prompts: $1:$2 uses ${hit% } — say what the model must do, in plain words (ADR-067)" >&2
    bad=$((bad + 1))
}

while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="${entry%%#*}"
    read -r rel mode <<< "$entry" || true
    [[ -n "${rel:-}" ]] || continue
    mode="${mode:-}"
    f="$ROOT/$rel"
    if [[ ! -f "$f" ]]; then
        echo "lint-plain-prompts: config/model-facing-sources.txt lists $rel, which does not exist" >&2
        bad=$((bad + 1)); continue
    fi
    files=$((files + 1))
    n=0
    if [[ "$f" == *.md ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            n=$((n + 1))
            _check "$rel" "$n" "$line"
        done < "$f"
        continue
    fi
    term="" cont=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        trimmed="${line#"${line%%[![:space:]]*}"}"
        # A stage summary call, and the lines it continues onto with `\`.
        if [[ -z "$term" && ( $cont -eq 1 || "$trimmed" == stage_summary_write* || "$trimmed" == *"clauses+=("* \
              || ( "$mode" == printf && "$trimmed" == printf* ) ) && "$trimmed" != \#* ]]; then
            _check "$rel" "$n" "$line"
            if [[ "$line" == *'\' ]]; then cont=1; else cont=0; fi
            continue
        fi
        if [[ -n "$term" ]]; then
            local_line="${line#"${line%%[!$'\t']*}"}"   # <<- strips leading tabs
            if [[ "$line" == "$term" || "$local_line" == "$term" ]]; then term=""; continue; fi
            _check "$rel" "$n" "$line"
            continue
        fi
        # A heredoc opener: <<WORD, <<-WORD, <<'WORD', <<"WORD".
        if [[ "$line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*)[\'\"]? ]]; then
            [[ "$line" == *"# not-model-facing"* ]] && { skip="${BASH_REMATCH[1]}"; term="";
                while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); [[ "${line#"${line%%[!$'\t']*}"}" == "$skip" ]] && break; done; continue; }
            term="${BASH_REMATCH[1]}"
        fi
    done < "$f"
done < "$LIST"

if [[ $bad -gt 0 ]]; then
    echo "lint-plain-prompts: $bad problem(s) in $files model-facing source(s)" >&2
    exit 1
fi
echo "lint-plain-prompts: $files model-facing source(s) checked, plain"
