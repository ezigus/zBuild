## spec-coverage — uncovered

- SPEC-1 asserts the code condition for "both simple.yaml and deployed.yaml" but its TESTFILES names only `tests/unit/template-simple-yaml-test.sh`; SPEC-3's T1 also loads only `simple.yaml` (confirmed at line 43 of the test file), so no SPEC names a test file that would fail if `impact` remained in `deployed.yaml`'s `delivery_loop`.

- NOT COVERED: R-1: the requirement is "a test asserting `impact` is absent from `delivery_loop` in **both** shipped templates" — SPEC-1 and SPEC-3 together enforce only `simple.yaml`
- NOT COVERED: no SPEC names a test file whose failure on main would catch `impact` still present in `deployed.yaml`'s `delivery_loop.flow`.
