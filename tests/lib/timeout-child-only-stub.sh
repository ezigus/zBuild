#!/usr/bin/env bash
# tests/lib/timeout-child-only-stub.sh — a `timeout` without GNU `timeout`'s
# group habits, for tests that must not rely on them (#2563, ADR-054 §11,
# ADR-062).
#
# Modelled on the Rust coreutils `timeout` Ubuntu 26.04 ships (uutils 0.12),
# and stricter than it where that keeps a test honest:
#   - it sets no handler for TERM: a TERM sent to it ends it at once (143), and
#     its command is not told and keeps running (as uutils does);
#   - on expiry it signals only its direct child, TERM and then KILL after -k
#     (uutils KILLs only the child; its TERM also reaches the child's group, so
#     the stub is stricter there);
#   - after a KILL it exits 137, as uutils does; a plain timeout exits 124.
# It takes whole seconds only, and says so for anything else.
#
# Usage, as `timeout`: timeout-child-only-stub.sh [-k <grace>] <duration> <cmd>...
# A test links it as `timeout` and `gtimeout` in a folder first on its PATH.

grace=""
if [[ "${1:-}" == "-k" ]]; then grace="$2"; shift 2; fi
dur="${1:?duration}"; shift
for _v in "$dur" ${grace:+"$grace"}; do
    [[ "$_v" =~ ^[0-9]+$ ]] || { printf 'timeout-child-only-stub: whole seconds only, not %s\n' "$_v" >&2; exit 125; }
done
# Its stdin is the command's: a backgrounded command would read /dev/null.
"$@" <&0 &
child=$!
# Poll in tenths of a second, each step checking the child: a TERM to us acts
# at once, and a command that ends early ends this at once.
ticks=$(( dur * 10 )); i=0
while (( i < ticks )); do
    kill -0 "$child" 2>/dev/null || { wait "$child"; exit $?; }
    sleep 0.1
    i=$(( i + 1 ))
done
kill -TERM "$child" 2>/dev/null
if [[ -n "$grace" ]]; then
    ticks=$(( grace * 10 )); i=0
    while (( i < ticks )); do
        kill -0 "$child" 2>/dev/null || exit 124
        sleep 0.1
        i=$(( i + 1 ))
    done
    kill -KILL "$child" 2>/dev/null
    exit 137
fi
exit 124
