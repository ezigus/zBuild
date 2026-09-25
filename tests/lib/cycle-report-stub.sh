#!/usr/bin/env bash
# tests/lib/cycle-report-stub.sh — #2189: a stubbed cycle_dispatch_stage hands the
# engine a member REPORT, as a real dispatch does (runner_read_stage_report).
#
# The cycle decides "tests failing" from the test counts members report, never
# from a member named `test`. A stub that plays the test stage must therefore
# report a count, exactly as plugins/tool/test writes data.failed.
#
#   zb_stub_reports_tests <member>
#       Wraps the cycle_dispatch_stage already defined: after it runs, <member>
#       reports tests.failed = 1 when its verdict is fail, else 0. Call it AFTER
#       defining the stub.

zb_stub_reports_tests() {
    local _zb_member="$1"
    declare -F cycle_dispatch_stage >/dev/null 2>&1 || return 1
    eval "$(declare -f cycle_dispatch_stage | sed '1s/^cycle_dispatch_stage/_zb_stub_dispatch_inner/')"
    _ZB_STUB_TEST_MEMBER="$_zb_member"
    cycle_dispatch_stage() {
        local _zb_rc=0
        _CYCLE_DISPATCH_REPORT="{}"
        _zb_stub_dispatch_inner "$@" || _zb_rc=$?
        if [[ "$1" == "$_ZB_STUB_TEST_MEMBER" ]]; then
            local _zb_failed=0
            [[ "${_CYCLE_DISPATCH_VERDICT_RAW:-${_CYCLE_DISPATCH_VERDICT:-}}" == "fail" ]] && _zb_failed=1
            _CYCLE_DISPATCH_REPORT="{\"tests\":{\"failed\":$_zb_failed}}"
        fi
        return "$_zb_rc"
    }
}
