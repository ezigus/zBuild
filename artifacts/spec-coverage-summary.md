## spec-coverage — covered

- Every requirement is addressed by at least one SPEC — R-1 by SPEC-2 and SPEC-6 (single-jq accumulation verified, fork budget lowered below merge-base measurement); R-2 by SPEC-1 (OSTYPE-based host detection tested with ZBUILD_PLATFORM=linux on a darwin host); R-3 by SPEC-5 (sidecar stage attribution) and SPEC-3 (cursor reset prevents the emitted event from re-arming dirty); R-4 by SPEC-3 (no second render) and SPEC-4 (no PATCH when body unchanged); R-5 by SPEC-6 (fork budget test fails on unpatched code) and SPEC-7 (ADR Enforced-by section names the test); R-6 by SPEC-2 (byte-for-byte identical output for same inputs).

- every requirement the issue states maps to a declared SPEC
