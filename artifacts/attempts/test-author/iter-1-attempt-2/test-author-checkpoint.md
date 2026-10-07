## Checkpoint — test-author, issue #2222, SPEC-3 (iteration 1/4 — DONE)

### Changes made this iteration
tests/unit/exhausted-disposition-retired-test.sh updated (190 lines):
a. Line 22: [no-code] → [code] in header comment
b. Line 48: removed [#2222/SPEC-3] from file-existence guard (assert_fail) — it's a prereq check, not a requirement assertion; having it as the first [#2222/SPEC-3] tagged assertion caused negctl to see it as the primary assertion and report no_code
c. After site 5 (line 96-101): added _adr054_dated assertion — grep -cE '6a\..*\(20[0-9]{2}-[0-9]{2}-[0-9]{2}' checks §6a heading has ISO date; satisfies "dated backward-pointer note" requirement
d. After R-4(b) (lines 164-185): added R-4(c) assertion for shell-assignment forms in core/plugins/scripts

### Test run result
10/10 assertions pass (all [#2222/SPEC-3] tagged)

### Status: COMPLETE
