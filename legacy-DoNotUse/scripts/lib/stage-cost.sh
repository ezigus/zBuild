#!/usr/bin/env bash
# Backward-compat shim — canonical location is lib/cost/stage.sh
# Sources the canonical implementation so existing callers continue to work.
[[ -n "${_STAGE_COST_LOADED:-}" ]] && return 0
_shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_shim_dir/cost/stage.sh" ]] && source "$_shim_dir/cost/stage.sh"
