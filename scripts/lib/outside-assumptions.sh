#!/usr/bin/env bash
# scripts/lib/outside-assumptions.sh — the one rule on what a change assumes
# about the world outside its own code (#2584, ADR-038, ADR-040).
#
# On #1764 the engine claimed an issue with the `zbuild:claimed` label, which
# did not exist in the repository, and no stage could see it. Design, build and
# the lenses are told the same rule, word for word, so what design names, build
# handles and a lens checks is one thing.
#
# Sourced library: no set -euo pipefail. Nothing here forks.
[[ -n "${_ZBUILD_OUTSIDE_ASSUMPTIONS_LOADED:-}" ]] && return 0
_ZBUILD_OUTSIDE_ASSUMPTIONS_LOADED=1

# shellcheck disable=SC2034  # read by the design, build and lens prompts
ZB_OUTSIDE_ASSUMPTIONS_RULE="Every assumption the change makes about something outside its own code is
named and handled: a service, a repository setting (a label, a branch rule, a
secret), an environment value, a data format, another program's output.
Handled means the code creates it; or checks it and fails clearly, with an
event or a status line; or the design says why it is safe to assume."
