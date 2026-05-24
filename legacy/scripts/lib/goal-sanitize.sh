#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  goal-sanitize.sh — Strip synthesized pipeline context from goal strings  ║
# ║                                                                          ║
# ║  Called at capture time (sw-loop.sh:419) and on resume                   ║
# ║  (loop-restart.sh, pipeline-state.sh).                                  ║
# ║                                                                          ║
# ║  Bash 3.2 safe: uses %% operator only, no regex, no associative arrays.  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

_strip_synthesized_sections() {
    local _s="$1"

    # Strip prefix forms first (KNOWN FIX prepended with blank line after)
    if [[ "$_s" == "KNOWN FIX (from past success):"* ]]; then
        _s="${_s#*$'\n\n'}"
    fi

    # Strip all suffix sentinels (Bash 3.2 safe: %% operator, no regex)
    _s="${_s%%$'\n\n## Plan Summary'*}"
    _s="${_s%%$'\n\n## Key Design Decisions'*}"
    _s="${_s%%$'\n\nIMPORTANT (TDD mode)'*}"
    _s="${_s%%$'\n\nHistorical context'*}"
    _s="${_s%%$'\n\nDiscoveries from'*}"
    _s="${_s%%$'\n\nFile hotspots'*}"
    _s="${_s%%$'\n\nActive security alerts'*}"
    _s="${_s%%$'\n\nCoverage baseline'*}"
    _s="${_s%%$'\n\n## Skill Guidance'*}"
    _s="${_s%%$'\n\n## Historical Build Context'*}"
    _s="${_s%%$'\n\nBLOCKING ISSUES'*}"
    _s="${_s%%$'\n\nIMPORTANT — Previous build'*}"
    _s="${_s%%$'\n\nIMPORTANT — Code review'*}"
    _s="${_s%%$'\n\nIMPORTANT — Architecture'*}"
    _s="${_s%%$'\n\nIMPORTANT — Compound quality'*}"
    _s="${_s%%$'\n\nHUMAN FEEDBACK'*}"
    _s="${_s%%$'\n\n## Previous Session Context'*}"
    _s="${_s%%$'\n\nWARNING: Memory system'*}"

    printf '%s' "$_s"
}
