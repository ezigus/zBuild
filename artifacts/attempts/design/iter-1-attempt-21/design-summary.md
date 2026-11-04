## design — fail

- the design fails 1 check(s)

- DLGT-1 Then 2 is not something a test can observe: describes what a test would observe if the implementation were reverted to a different form, not an observable output of the When's execution — "When plugin.sh is reverted to calling _hydrate_put_back inline, the sentinel is not written and the assertion fails". Rewrite it as what someone could see the code do after the When

This try is kept as the working copy for the next run; design.md is unchanged.
