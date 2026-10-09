#!/usr/bin/env bash
# Backward-compat shim — canonical location is lib/cost/iteration.sh
# Sources the canonical implementation so existing callers continue to work.
[[ -n "${_LOOP_COST_LOADED:-}" ]] && return 0
_shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_shim_dir/cost/iteration.sh" ]] && source "$_shim_dir/cost/iteration.sh"
