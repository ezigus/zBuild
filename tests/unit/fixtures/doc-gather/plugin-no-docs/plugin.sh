#!/usr/bin/env bash
# Stub plugin for doc-gather fixture (plugin-no-docs). Not a real plugin.
[[ -n "${_ZBUILD_DOC_GATHER_NODOCS_LOADED:-}" ]] && return 0
_ZBUILD_DOC_GATHER_NODOCS_LOADED=1

nodocs_run() { return 0; }
