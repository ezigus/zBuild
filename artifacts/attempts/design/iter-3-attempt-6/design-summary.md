## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done — Changed DSCLA-18 from `[no-code]` to `[code]`. The finding is correct: `config/shape-change-paths.txt` does not exist in the base code, so `_test_list_file_v` leaves `_tlf=""` and the shape-tests block is never entered — the test fails on the old code and passes after the step that adds `core/claim/claim.sh` to that file. The status is `[code]`.
