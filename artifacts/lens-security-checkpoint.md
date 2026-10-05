# Security lens checkpoint — issue #2032

## Files read
- `scripts/lib/router-rc-classify.sh` lines 139–180 + 276–291: `_router_rc_classify` uses a `case "$rc" in` with numeric literals; `*` wildcard returns `router_rc_nonzero → unavailable`. `router_reason_disposition` is a closed `case` returning fixed string constants. No exec or eval. Safe.
- `plugins/agent/spec-coverage/plugin.sh` lines 175–228: mktemp pattern confirmed. `_rtm_rc` used only in `[[ ... -ne 0 ]]`. Disposition written via `jq --arg`.
- `plugins/agent/spec-correspondence/plugin.sh` lines 110–170: same rc-file pattern. `_rc_file` always mktemp-generated.
- `plugins/agent/review-report/plugin.sh` lines 155–185: `_rr_lens_rc` from `cat artifact_dir/lens-${_rr_lens_name}.rc`. `_RR_LENSES` comes from manifest.yaml parsed by awk (pre-existing).
- `plugins/agent/review-report/lib/lenses.sh` lines 17–43: awk extracts lens names; pattern `/^    - [a-z]/` validates first char is lowercase but does NOT exclude `/` in subsequent chars — path traversal possible from manifest, but pre-existing, manifest is repo file not user input.

## Conclusions

**Introduced — Low**: Temp files in `/tmp` (`spec-coverage`, `spec-correspondence`). `mktemp` sets mode 600 but a local attacker with access to the CI environment could replace the temp file between write and read to swap the rc value (controlling which disposition word is emitted). Blast radius: at worst `complete` disposition instead of `timed_out`, reinstating the exact bug this PR fixes. Pattern is documented design (subshell boundary) and already used in review-lens. Not exploitable remotely.

**Pre-existing — Low**: `artifact_dir/lens-${_rr_lens_name}.rc` path construction. `_RR_LENSES` loaded from manifest with awk that only validates first char is `[a-z]`; a value like `a/../../../etc/passwd` would pass. Unchanged by this diff. Manifest is a repo file, not user-controlled.

**No findings**: jq injection — all disposition strings from `router_reason_disposition` go through `--arg` (string-escaped). No command injection — rc file path is always mktemp-generated or `/dev/null`. No credentials. No SIGPIPE antipatterns introduced. No model names hardcoded.

## What I would do next
Nothing — analysis is complete.
