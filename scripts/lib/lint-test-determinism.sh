#!/usr/bin/env bash
# scripts/lib/lint-test-determinism.sh — tests are deterministic (ADR-012
# amendment 2026-11-08).
#
# A test never depends on a remote service or on a clock. The cache-gh-actions
# "interrupted push" test started a push, slept 0.1s and sent KILL: on an idle
# machine the push had already finished, so nothing was interrupted, and under
# load the kill landed mid-copy and the test failed. In tests/ and in each
# plugin's tests/ (not legacy-DoNotUse/) this lint fails on:
#   remote      a call to gh, claude, curl or wget in a file that installs no
#               mock for that command, or a call by absolute path, which goes
#               past any mock on PATH. A file mocks a command when it calls
#               mock_<cmd>, mock_binary <cmd> or install_envelope_mock_claude,
#               or writes a script to a path ending in /<cmd>.
#   clock       a read of the clock — $SECONDS, `date +%s` — to see how long
#               something took (#2525: on #1805 run 43093018140 a busy machine
#               turned a 15 s bound into 16 s). Check what shows the thing
#               happened — an outcome, an event, a marker — not how long it took.
#   own-code    (#2630) a definition of a function our own code defines — under
#               core/, scripts/, or plugins/ outside a plugin's tests/ — which
#               replaces it with a fake: the test then tests the fake. An
#               outside service is faked at our own wrapper around it, listed in
#               config/test-fake-wrappers.txt (the model call, GitHub); those
#               may be redefined. A definition in a heredoc (a fake plugin
#               written to disk) is not one, nor a spy whose body (on its
#               line) calls a copy of the original (a name with orig or real
#               as a part), nor a define-if-missing guard (declare -F <f>
#               [redirs] || <f>() {…}). A test-local helper whose name only
#               collides with a private production one is marked
#               `# determinism-ok: test-local helper`.
#   sleep-kill  a `sleep` followed, within three commands, by a `kill`: a
#               signal timed by a clock. Wait for a marker the process writes
#               at the point under test, with a timeout, then signal. A poll
#               loop (the sleep inside a loop), a background sleeper
#               (`sleep 30 &`) and `kill -0` (a liveness check) are not this.
# Signals sent to the engine's own processes stay real: signal handling is our
# code under test, and only the sleep that times them is refused.
#
# Only what a file runs is read: comments, quoted text and heredoc bodies
# (where mocks are written) are not calls (zb_shell_code_named). Mocks are found
# in the raw text, since a mock's name or path is often quoted (`mock_binary
# "gh"`) and its script a heredoc; so a mock's name in a string or a comment
# also counts as a mock (a known blind spot, review on #2500). A line may opt
# out with
#   # determinism-ok: <reason>
# and the reason is required. On a sleep-kill, the mark may sit on either line.
#
# Findings that predate the rule are listed in config/test-determinism-baseline.txt
# as `<kind>|<file>|<the line, trimmed>`. The list only shrinks: a finding not on
# it fails, and an entry that matches no finding fails until it is removed.
#
# Usage: bash scripts/lib/lint-test-determinism.sh [repo_root]
# Exit:  0 clean; 1 one or more findings (each printed as file:line: text).
set -euo pipefail

_LTD_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
ROOT="${1:-$(cd "$_LTD_DIR/../.." && pwd)}"
BASELINE="$ROOT/config/test-determinism-baseline.txt"
# shellcheck source=shell-join.sh
source "$_LTD_DIR/shell-join.sh"

cd "$ROOT"
files=()
while IFS= read -r -d '' f; do files+=("${f#./}"); done < <(
    { [[ -d tests ]] && find ./tests -name '*.sh' -print0
      [[ -d plugins ]] && find ./plugins -path '*/tests/*' -name '*.sh' -print0; } 2>/dev/null || true)
(( ${#files[@]} > 0 )) || exit 0

# The marks and the mocks are read from each file's raw text: a mark is a
# comment, and a mock is often a script written by a heredoc.
marks="$(/usr/bin/grep -HnE '#[[:space:]]*determinism-ok:' "${files[@]}" 2>/dev/null || true)"
mocks="$(/usr/bin/grep -HoE "mock_(gh|claude|curl|wget)\b|mock_binary[[:space:]]+[\"']?(gh|claude|curl|wget)[\"']?([[:space:]]|$)|install_envelope_mock_claude|>[[:space:]]*[\"']?[^[:space:]\"']*/(gh|claude|curl|wget)[\"']?([[:space:]]|$)" \
    "${files[@]}" 2>/dev/null || true)"

# #2630: the functions our own code defines, and the wrappers around outside
# services a test may fake. One grep over the production files.
prod=()
while IFS= read -r -d '' f; do prod+=("${f#./}"); done < <(
    { for d in core scripts plugins; do [[ -d "$d" ]] && find "./$d" -name '*.sh' -not -path '*/tests/*' -not -path '*/legacy-DoNotUse/*' -print0; done; } 2>/dev/null || true)
own=""
(( ${#prod[@]} > 0 )) && own="$(/usr/bin/grep -hoE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)' "${prod[@]}" 2>/dev/null \
    | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)$//' | sort -u || true)"
allow=""
[[ -f "$ROOT/config/test-fake-wrappers.txt" ]] && allow="$(/usr/bin/grep -vE '^[[:space:]]*(#|$)' "$ROOT/config/test-fake-wrappers.txt" || true)"

# One stream into awk: the marks (M), the mocks (K), our functions (F), the
# allowed wrappers (A), then the code (C).
findings="$(awk '
BEGIN { P = "(^|[;&|(`!{]|[$][(]|(then|do|else|command|exec|if|while|until|time|xargs|env)[ \t])[ \t]*" }
function at(c, w) { return match(c, P w "([ \t;|&)]|$)") }
function bad(f, l, why) { printf "%s|%s|%s\n", f, l, why }
# #2630: not a fake — a define-if-missing guard, `declare -F <f> [redirs] ||`
# right before the definition; or a spy, whose body (the rest of the line after
# the definition) calls a copy of the original: a command named with orig or
# real as a part of it (<f>_orig, _orig_<f>, _real_<f>, _m12_orig_<f>, _yg_real).
# A spy whose body is on the lines below stays in the baseline.
# A name is read as text: of the characters the name in a definition may hold
# ([A-Za-z0-9_:.-]) only . means something in a pattern.
function lit(n) { gsub(/[.]/, "[.]", n); return n }
function guarded(before, n) {
    gsub(/[0-9]*>&[0-9-]+/, "", before); gsub(/&>>?/, ">", before)
    return match(before, "declare[ \t]+-F[ \t]+" lit(n) "([ \t]+[^|&;]*)?[ \t]*[|][|][ \t]*$")
}
# A copy is called where the lint reads any command (P), not read as ${…}.
function spybody(after, n,   id, p) {
    p = ""
    while (match(after, /[A-Za-z_][A-Za-z0-9_]*/)) {
        id = substr(after, RSTART, RLENGTH); p = p substr(after, 1, RSTART - 1); after = substr(after, RSTART + RLENGTH)
        if (id != n && id ~ /(^|_)(orig|real)(_|$)/ && p !~ /[$][{]$/ && match(p, P "$")) return 1
        p = p id
    }
    return 0
}
{ tag = substr($0, 1, 1); $0 = substr($0, 3) }
tag == "M" {
    f = $0; sub(/:.*/, "", f); r = substr($0, length(f) + 2); l = r; sub(/:.*/, "", l)
    reason = r; sub(/.*determinism-ok:[ \t]*/, "", reason)
    mark[f ":" l] = (reason ~ /[^ \t]/) ? "ok" : "bare"; next
}
tag == "F" { ownf[$0] = 1; next }
tag == "A" { allowf[$0] = 1; next }
tag == "K" {
    f = $0; sub(/:.*/, "", f); t = substr($0, length(f) + 2)
    if (t ~ /install_envelope_mock_claude/) { mocked[f, "claude"] = 1; next }
    if (match(t, /(gh|claude|curl|wget)[^a-z]*$/)) { c = substr(t, RSTART); sub(/[^a-z].*/, "", c); mocked[f, c] = 1 }
    next
}
{
    i = index($0, ":"); f = substr($0, 1, i - 1); r = substr($0, i + 1)
    j = index(r, ":"); l = substr(r, 1, j - 1); c = substr(r, j + 1)
    if (f != pf) { left = 0; pf = f }
    if (mark[f ":" l] == "bare") bad(f, l, "mark|a determinism-ok mark needs its reason")
    if (c !~ /[^ \t]/) next
    if (mark[f ":" l] != "ok" && at(c, "(/[A-Za-z0-9_./-]*/)?(gh|claude|curl|wget)")) {
        s = substr(c, RSTART, RLENGTH); sub(/[ \t;|&)]$/, "", s); sub(/^.*[ \t;&|(`!{]/, "", s)
        abs = (s ~ /^\//); cmd = s; sub(/.*\//, "", cmd); sub(/[^a-z].*/, "", cmd)
        if (abs) bad(f, l, "remote|calls " cmd " by its path, past any mock")
        else if (!mocked[f, cmd]) bad(f, l, "remote|calls " cmd " with no mock in the file")
    }
    if (mark[f ":" l] != "ok") {
        d = c; pre = ""
        while (match(d, /(^|[;&|(!{ \t])(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*[(][)]/)) {
            n = substr(d, RSTART, RLENGTH); bef = pre substr(d, 1, RSTART); aft = substr(d, RSTART + RLENGTH)
            pre = pre substr(d, 1, RSTART + RLENGTH - 1); d = aft
            sub(/^[;&|(!{ \t]/, "", n); sub(/^function[ \t]+/, "", n); sub(/[ \t]*[(][)]$/, "", n)
            if (ownf[n] && !allowf[n] && !guarded(bef, n) && !spybody(aft, n)) { bad(f, l, "own-code|replaces " n ", which our own code defines, with a fake"); break }
        }
        if (match(c, /(^|[;&|(!{ \t])function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*[{]/)) {
            n = substr(c, RSTART, RLENGTH); bef = substr(c, 1, RSTART); aft = substr(c, RSTART + RLENGTH)
            sub(/^.*function[ \t]+/, "", n); sub(/[ \t]*[{]$/, "", n)
            if (ownf[n] && !allowf[n] && !guarded(bef, n) && !spybody(aft, n)) bad(f, l, "own-code|replaces " n ", which our own code defines, with a fake")
        }
    }
    if (mark[f ":" l] != "ok" && c ~ /([$][{]?SECONDS([^A-Za-z0-9_]|$)|[(][(]([^)]*[^A-Za-z0-9_)])?SECONDS([^A-Za-z0-9_]|$)|date([ \t]+-[A-Za-z]+)*[ \t]+["'"'"']?[+]%s)/) bad(f, l, "clock|reads the clock to time something")
    loop = (c ~ /(^|[;&| \t])done([ \t;|&)]|$)/)
    if (left > 0) {
        if (loop) left = 0
        else if (at(c, "kill") && c !~ /kill[ \t]+(-0|-s[ \t]+0)([ \t]|$)/) {
            if (mark[f ":" l] != "ok" && mark[f ":" sl] != "ok") bad(f, sl, "sleep-kill|a signal timed by a sleep")
            left = 0
        } else left--
    }
    if (at(c, "sleep")) {
        t = c; sub(/[ \t]+$/, "", t)
        rest = substr(c, RSTART + RLENGTH)
        if (loop || c ~ /(^|[ \t;])(while|until|for)[ \t]/ || rest ~ /(^|[^&>])&([^&>]|$)/) next
        if (at(rest, "kill") && rest !~ /kill[ \t]+(-0|-s[ \t]+0)([ \t]|$)/) {
            if (mark[f ":" l] != "ok") bad(f, l, "sleep-kill|a signal timed by a sleep")
        } else { left = 3; sl = l }
    }
}' < <(
    [[ -n "$marks" ]] && sed 's/^/M /' <<< "$marks"
    [[ -n "$mocks" ]] && sed 's/^/K /' <<< "$mocks"
    [[ -n "$own" ]] && sed 's/^/F /' <<< "$own"
    [[ -n "$allow" ]] && sed 's/^/A /' <<< "$allow"
    zb_shell_code_named "${files[@]}" | sed 's/^/C /'))"

# Each finding is keyed by its kind, file and line text, so the baseline does
# not move when lines do.
declare -A listed=()
if [[ -f "$BASELINE" ]]; then
    while IFS= read -r _b || [[ -n "$_b" ]]; do
        [[ -z "${_b//[[:space:]]/}" || "$_b" == \#* ]] && continue
        listed["$_b"]=$(( ${listed["$_b"]:-0} + 1 ))
    done < "$BASELINE"
fi

out=""
while IFS='|' read -r f l kind why; do
    [[ -n "$f" ]] || continue
    _text="$(sed -n "${l}p" "$f")"
    _text="${_text#"${_text%%[![:space:]]*}"}"; _text="${_text%"${_text##*[![:space:]]}"}"
    key="$kind|$f|$_text"
    if [[ "${listed["$key"]:-0}" -gt 0 ]]; then
        listed["$key"]=$(( listed["$key"] - 1 )); continue
    fi
    out+="$f:$l: $why: $_text"$'\n'
done <<< "$findings"
for key in "${!listed[@]}"; do
    (( listed["$key"] > 0 )) && out+="config/test-determinism-baseline.txt: $key — no longer found; remove the entry"$'\n'
done

if [[ -n "$out" ]]; then
    printf '%s' "$out" >&2
    echo "lint-test-determinism: mock the remote service (mock_binary <cmd>), or wait for a marker the process writes before signalling it; a line that must stay may be marked '# determinism-ok: <reason>' (ADR-012)" >&2
    exit 1
fi
exit 0
