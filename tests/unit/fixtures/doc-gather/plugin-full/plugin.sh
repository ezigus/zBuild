#!/usr/bin/env bash
# Stub plugin for doc-gather fixture (plugin-full). Not a real plugin.
[[ -n "${_ZBUILD_DOC_GATHER_FULL_LOADED:-}" ]] && return 0
_ZBUILD_DOC_GATHER_FULL_LOADED=1

fixture_init()     { return 0; }
fixture_run()      { return 0; }
fixture_finalize() { return 0; }
fixture_cleanup()  { return 0; }
