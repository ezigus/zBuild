## review-lens-scope — fail

- found: high: The `stage.start` guard in `_cycle_dispatch` lacks the required `_ZBUILD_RESUME_ACTIVE` check, so ALL fresh cycle-based runs now emit extra `stage.start` events for every cycle member at iter > 0, changing the event contract beyond what the issue asked for. (core/pipeline/runner.sh:3204) (and 1 more)

- high: The `stage.start` guard in `_cycle_dispatch` lacks the required `_ZBUILD_RESUME_ACTIVE` check, so ALL fresh cycle-based runs now emit extra `stage.start` events for every cycle member at iter > 0, changing the event contract beyond what the issue asked for. (core/pipeline/runner.sh:3204)
- medium: Path 2 (auto-resume) passes `ZBUILD_STATE_FILE="$P2_STATE_FILE"` explicitly, so the new `latest`-symlink auto-resume branch (runner.sh's `elif ! $no_resume && [[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]`) is never exercised; ENTR-2 is checked by this file according to the issue but the symlink path is untested. (tests/integration/resume-entry-points-test.sh:215)
- score: 6
