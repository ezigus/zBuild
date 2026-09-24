## spec-correspondence — mismatch

- judged 1 SPEC(s): 0 correspond, 0 partial, 1 mismatch, 0 uncheckable, 0 unjudged

- SPEC-4 MISMATCH: the assertion checks only that the linter accepts an explicit empty `valid_verdicts: []` with rc=0 — it tests linter permissiveness toward the old state, not that pr-open's manifest was updated to `result_contract==2`, not that `valid_verdicts` was changed to `[pass,blocked,error]`, and not that `verdict_classify('blocked')` returns `'fail'`.

