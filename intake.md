[zbuild-test] throwaway issue for #2131 live status comment verification

Throwaway. Used to verify PR #2136's live run-status comment (local run + CI daemon run). Safe to close after.

## Additional context from issue comments

<!-- zbuild-run-status run_id=20260918185249-19075 -->
### zbuild run `20260918185249-19075` · issue #2137 · **interrupted**
engine `1e8800f` (`zbuild/issue-2131-run-status-comment`) · started 2026-09-18T22:52:49Z · updated 2026-09-18T22:58:14Z · sigterm
**5 impact** · 22:57:34Z → running · inputs: scope_manifest, design, plan · 6 stage summaries (0 RESOLVE)
**4.1.3 design-gate** · iter 1 · 22:57:32Z → 22:57:33Z (1s) · **pass** — The design is build-ready.
**4.1.2 spec-coverage** · iter 1 · 22:57:14Z → 22:57:31Z (17s) · **covered** — The issue is a throwaway with no enumerated requirements — its sole purpose is to exercise the live run-status comment path, which SPEC-1 and SPEC-2 directly cover.
**4.1.1 design** · iter 1 · 22:53:07Z → 22:57:14Z (4m07s) · **pass** — authored design.md — 9 file(s) in scope, 4 acceptance SPEC(s)
**3 plan** · 22:52:56Z → 22:53:06Z (10s) · **pass** — decomposed the goal into 1 step(s)
**2 intake** · 22:52:54Z → 22:52:56Z (2s) · **pass** — took in the goal for issue #2137: [zbuild-test] throwaway issue for #2131 live status comment 
**1 hydrate** · 22:52:52Z → 22:52:54Z (2s) · **pass** — restored 10 artifact(s) from prior runs (restored)
