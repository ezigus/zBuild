#!/usr/bin/env bash
# scripts/lib/fork-census.sh — count the external programs a command starts
# (ADR-065 §1).
#
# The suite is slow because it starts programs, not because it computes: one
# test file can start 20,000. This runs a command under bash xtrace (BASH_ENV
# injects `set -x` into every child bash, PS4 stamps source:line, BASH_XTRACEFD=7
# routes it to one file — fd 3 is stage-io, 8 is coverage, 9 is flock) and
# counts every command word that resolves to a program on PATH.
#
#   bash scripts/lib/fork-census.sh <cmd...>   → the count, top call sites, per-file totals
#   source it → fork_census_traced <trace> <cmd...>; fork_census_count <trace> <sites_out>
#
# tests/e2e/fork-budget-test.sh holds the engine to FORK_BUDGET with these same
# two functions.

# Usage: fork_census_traced <trace_file> <cmd...> — runs cmd with tracing to trace_file.
fork_census_traced() {
    local trace="$1"; shift
    local be="${trace}.bashenv"
    printf 'set -x\n' > "$be"
    (
        # #<pid> after the line number names the process each line ran in
        # (fork_census_processes); the counter strips it.
        export PS4='+@${BASH_SOURCE[0]-}:${LINENO}#${BASHPID}@ '
        export BASH_XTRACEFD=7
        export BASH_ENV="$be"
        "$@" 7>"$trace"
    )
}

# Usage: fork_census_count <trace_file> <sites_out>
# Prints the number of external execs; writes `count<TAB>file:line<TAB>cmd`
# rows (descending) to sites_out. A word is external when the TEST shell
# resolves it to a file on PATH (engine functions are not sourced here, so a
# function named like nothing on PATH is not counted), or it is one of the
# fixture's mocks. Leading `VAR=val` words and wrappers (exec, command, env,
# nice, timeout N) are stripped so the wrapped command is classified — and the
# wrapper counted too when it is itself a binary.
# A source line marked `# fork-budget-exempt: <why>` is a wait whose repeat count
# is elapsed time, not code (#2236): its rows go to <sites_out>.exempt instead.
fork_census_count() {
    local trace="$1" sites="$2"
    local pairs="${sites}.pairs" exempt="${sites}.exemptlines"
    # The marked lines of every traced source file, as `path:line`.
    : > "$exempt"
    local src
    while IFS= read -r src; do
        [[ -f "$src" ]] || continue
        grep -n 'fork-budget-exempt:' "$src" 2>/dev/null | awk -F: -v p="$src" '{ print p ":" $1 }' >> "$exempt" || true
    done < <(awk '/^\++@[^@]*@ /{ s = $0; sub(/^\++@/, "", s); sub(/:[0-9]*(#[0-9]+)?@ .*$/, "", s); if (!(s in seen)) { seen[s] = 1; print s } }' "$trace")
    # pass 1: one `site<TAB>word` row per candidate command word (no forks per line);
    # an exempt site's row is tagged so pass 2 lists it apart.
    awk -v exf="$exempt" '
        BEGIN { while ((getline l < exf) > 0) ex[l] = 1 }
        /^\++@[^@]*@ / {
            site = $0; sub(/^\++@/, "", site); sub(/@ .*$/, "", site); sub(/#[0-9]+$/, "", site)
            tag = (site in ex) ? "\tX" : ""
            n = split(site, sp, "/"); site = sp[n]
            line = $0; sub(/^\++@[^@]*@ /, "", line)
            m = split(line, w, " ")
            for (i = 1; i <= m; i++) {
                t = w[i]
                if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {                  # VAR=val prefix
                    # xtrace single-quotes a value with spaces (v=<q>a b c<q>,
                    # q = 0x27). Its words are data: skip to the closing quote.
                    v = t; sub(/^[A-Za-z_][A-Za-z0-9_]*=/, "", v)
                    if (v ~ /^\$?\x27/ && !(length(v) > 1 && v ~ /\x27$/ && v !~ /^\$?\x27$/)) {
                        while (i < m && w[i] !~ /\x27$/) i++
                        if (w[i] !~ /\x27$/) i++
                    }
                    continue
                }
                if (t == "exec" || t == "command" || t == "env" || t == "nice") continue
                # `timeout N cmd` is two processes — timeout forks cmd so it can
                # kill it — so both are counted (one row each), and N is skipped.
                if ((t == "timeout" || t == "gtimeout") && i < m) { print site "\t" t tag; i++; continue }
                gsub(/^[\x27"]|[\x27"]$/, "", t)
                print site "\t" t tag
                break
            }
        }' "$trace" > "$pairs"
    # classify each unique word once in this shell
    local w kind; local -A ext=()
    for w in claude gh git rsync; do ext["$w"]=1; done
    while IFS= read -r w; do
        [[ -n "$w" && -z "${ext[$w]+x}" ]] || continue
        kind="$(type -t -- "$w" 2>/dev/null || true)"
        [[ "$kind" == "file" ]] && ext["$w"]=1
    done < <(cut -f2 "$pairs" | sort -u)
    # pass 2: keep external rows, tally by site. The site table goes through a
    # temp file and a synchronous sort — a `2> >(sort …)` process substitution
    # would return before sort finished writing (review on #2153).
    local extlist=""; for w in "${!ext[@]}"; do extlist+="$w "; done
    local unsorted="${sites}.unsorted"
    awk -v extlist="$extlist" -v out="$unsorted" -v xout="$unsorted.x" '
        BEGIN { n = split(extlist, a, " "); for (i = 1; i <= n; i++) ext[a[i]] = 1 }
        BEGIN { FS = "\t" }
        ($2 in ext) && $3 == "X" { xsite[$1 "\t" $2]++; next }
        ($2 in ext) { total++; site[$1 "\t" $2]++ }
        END {
            printf "" > out; printf "" > xout
            for (k in site) printf "%d\t%s\n", site[k], k > out
            for (k in xsite) printf "%d\t%s\n", xsite[k], k > xout
            close(out); close(xout)
            print total + 0
        }' "$pairs"
    sort -rn "$unsorted" > "$sites" 2>/dev/null || : > "$sites"
    sort -rn "$unsorted.x" > "$sites.exempt" 2>/dev/null || : > "$sites.exempt"
    rm -f "$pairs" "$unsorted" "$unsorted.x" "$exempt"
}

# Usage: fork_census_processes <trace_file> — the number of processes bash ran
# in: the command, every `$( )` / `( )` subshell (a copy of the whole shell,
# which fork_census_count does not see) and every subshell that execs a program.
fork_census_processes() {
    awk '/^\++@/ { p = $0; sub(/@ .*$/, "", p); sub(/^.*#/, "", p); if (!(p in seen)) { seen[p] = 1; n++ } } END { print n + 0 }' "$1"
}

# The census of one command, for a person: the count, the top call sites and
# the per-file totals. The command's own output is discarded; its rc is kept.
fork_census_report() {
    local tmp rc sites n
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/fork-census.XXXXXX")" || return 1
    sites="$tmp/sites"
    fork_census_traced "$tmp/trace" "$@" >/dev/null 2>&1; rc=$?
    n="$(fork_census_count "$tmp/trace" "$sites")"
    printf 'external execs: %s (rc %s)\n' "$n" "$rc"
    printf 'processes: %s\n' "$(fork_census_processes "$tmp/trace")"
    printf 'top call sites:\n'
    awk -F'\t' 'NR <= 20 { printf "  %6d  %-40s %s\n", $1, $2, $3 }' "$sites"
    printf 'by file:\n'
    awk -F'\t' '{ split($2, p, ":"); f[p[1]] += $1 } END { for (k in f) printf "%d\t%s\n", f[k], k }' "$sites" \
        | sort -rn | awk -F'\t' 'NR <= 15 { printf "  %6d  %s\n", $1, $2 }'
    rm -rf "$tmp"
    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    (( $# > 0 )) || { echo "usage: $0 <cmd...>" >&2; exit 2; }
    fork_census_report "$@"
fi
