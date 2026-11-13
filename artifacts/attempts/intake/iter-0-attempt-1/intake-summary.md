## intake — pass

- 8 requirement(s): RQDIFF-1, RQDIFF-2, RQDIFF-3, RQEND-1, RQLOCK-1, RQLOCK-2, RQLOCK-3, RQLOCK-4

- RQDIFF-1: Build's call ends on `no_done_sentinel` with zero files changed. `build.discrepancy.detected` is emitted, with the end reason in the event.
- RQDIFF-2: Build's call ends on `router_out_of_turns` with zero files changed. `build.discrepancy.detected` is emitted, with the end reason in the event.
- RQDIFF-3: Build's call ends on `done_sentinel` with zero files changed. Behavior remains as today.
- RQEND-1: A test collects every value `route_to_model_loop` assigns as its end reason and every reason `_router_rc_classify` returns, and checks the comment lists exactly that set.
- RQLOCK-1: No end-reason value is renamed or added.
- RQLOCK-2: The only change in `core/router/route.sh` is the comment.
- RQLOCK-3: `scripts/lib/router-rc-classify.sh` is not changed.
- RQLOCK-4: `tests/unit/route-one-call-per-try-test.sh` O4 is unchanged.
