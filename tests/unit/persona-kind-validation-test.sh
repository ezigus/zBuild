#!/usr/bin/env bash
# tests/unit/persona-kind-validation-test.sh
# Unit tests for the kind:persona manifest schema + validation (issue #1304).
# A persona is DATA-only (no plugin.sh / hooks); it MUST declare persona.role.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"

print_test_header "kind:persona manifest schema + validation (issue #1304)"

setup_test_env "persona-kind-validation"
FIXTURE_DIR="$TEST_TEMP_DIR/fixtures"
mkdir -p "$FIXTURE_DIR"

# ─── SPEC-1: persona is a recognized kind ────────────────────────────────────
found=0
for k in "${ZBUILD_PLUGIN_KINDS[@]}"; do
    [[ "$k" == "persona" ]] && found=1
done
assert_eq "[SPEC-1] 'persona' is registered in ZBUILD_PLUGIN_KINDS" "1" "$found"

# ─── SPEC-2: data-only persona with persona.role validates (no plugin.sh/hooks) ─
MANIFEST="$FIXTURE_DIR/valid-persona.yaml"
cat > "$MANIFEST" <<'EOF'
id: architect
name: Software Architect
kind: persona
version: 0.1.0
summary: Structure, boundaries, long-term evolution.
persona:
  role: a software architect
  perspective: Judge structure, boundaries, coupling, and conceptual integrity.
EOF

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-2] kind:persona with persona.role validates (no plugin.sh/hooks needed)" "0" "$rc"

# ─── SPEC-3: persona missing persona.role fails loudly ───────────────────────
MANIFEST="$FIXTURE_DIR/no-role-persona.yaml"
cat > "$MANIFEST" <<'EOF'
id: no-role
name: No Role Persona
kind: persona
version: 0.1.0
persona:
  perspective: A mindset without an identity.
EOF

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
set -e
assert_eq "[SPEC-3] kind:persona missing persona.role fails validation" "1" "$rc"
assert_contains "[SPEC-3] error names persona.role" "$err_out" "persona.role"

# ─── SPEC-4: persona with an entirely absent persona: block fails ────────────
MANIFEST="$FIXTURE_DIR/no-block-persona.yaml"
cat > "$MANIFEST" <<'EOF'
id: no-block
name: No Persona Block
kind: persona
version: 0.1.0
EOF

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-4] kind:persona with no persona.role at all fails validation" "1" "$rc"

# ─── SPEC-5: persona is EXEMPT from the kind:agent redaction requirement ──────
# A kind:agent manifest without requires.core.redaction fails; the same shape as
# a persona (no requires block) must PASS for kind:persona.
MANIFEST="$FIXTURE_DIR/persona-no-redaction.yaml"
cat > "$MANIFEST" <<'EOF'
id: security
name: Security Engineer
kind: persona
version: 0.1.0
persona:
  role: a security engineer
EOF

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-5] kind:persona is exempt from the agent redaction-declaration check" "0" "$rc"

# ─── SPEC-6: control — the SAME shape as kind:agent still fails (guards SPEC-5) ─
MANIFEST="$FIXTURE_DIR/agent-no-redaction.yaml"
cat > "$MANIFEST" <<'EOF'
id: some-agent
name: Some Agent
kind: agent
version: 0.1.0
hooks:
  run: some_agent_run
EOF

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-6] control: kind:agent without requires.core.redaction still fails" "1" "$rc"

# ─── SPEC-7: persona.role declared as '>' fails with message naming the field ──
MANIFEST="$FIXTURE_DIR/role-block-gt.yaml"
cat > "$MANIFEST" <<'EOF'
id: bad-role-gt
name: Bad Role GT
kind: persona
version: 0.1.0
persona:
  role: >
    A software architect who thinks in systems.
  perspective: Structure and boundaries.
EOF

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
rc=$?
set -e
assert_eq "[SPEC-7] persona.role declared as '>' fails validation" "1" "$rc"
assert_contains "[SPEC-7] error names persona.role field" "$err_out" "persona.role"

# ─── SPEC-8: persona.perspective declared as '>' fails with message naming field
MANIFEST="$FIXTURE_DIR/perspective-block-gt.yaml"
cat > "$MANIFEST" <<'EOF'
id: bad-persp-gt
name: Bad Perspective GT
kind: persona
version: 0.1.0
persona:
  role: a software architect
  perspective: >
    Judge structure, boundaries, and coupling.
EOF

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
rc=$?
set -e
assert_eq "[SPEC-8] persona.perspective declared as '>' fails validation" "1" "$rc"
assert_contains "[SPEC-8] error names persona.perspective field" "$err_out" "persona.perspective"

# ─── SPEC-9: persona.role declared as '>-' fails ─────────────────────────────
MANIFEST="$FIXTURE_DIR/role-block-gt-strip.yaml"
cat > "$MANIFEST" <<'EOF'
id: bad-role-gts
name: Bad Role GT-Strip
kind: persona
version: 0.1.0
persona:
  role: >-
    A software architect who thinks in systems.
  perspective: Structure and boundaries.
EOF

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
rc=$?
set -e
assert_eq "[SPEC-9] persona.role declared as '>-' fails validation" "1" "$rc"
assert_contains "[SPEC-9] error names persona.role field (>-)" "$err_out" "persona.role"

# ─── SPEC-10: persona.perspective declared as '>-' fails ─────────────────────
MANIFEST="$FIXTURE_DIR/perspective-block-gt-strip.yaml"
cat > "$MANIFEST" <<'EOF'
id: bad-persp-gts
name: Bad Perspective GT-Strip
kind: persona
version: 0.1.0
persona:
  role: a software architect
  perspective: >-
    Judge structure, boundaries, and coupling.
EOF

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
rc=$?
set -e
assert_eq "[SPEC-10] persona.perspective declared as '>-' fails validation" "1" "$rc"
assert_contains "[SPEC-10] error names persona.perspective field (>-)" "$err_out" "persona.perspective"

# ─── SPEC-11: persona.role declared as '|' fails ─────────────────────────────
MANIFEST="$FIXTURE_DIR/role-block-pipe.yaml"
cat > "$MANIFEST" <<'EOF'
id: bad-role-pipe
name: Bad Role Pipe
kind: persona
version: 0.1.0
persona:
  role: |
    A software architect who thinks in systems.
  perspective: Structure and boundaries.
EOF

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
rc=$?
set -e
assert_eq "[SPEC-11] persona.role declared as '|' fails validation" "1" "$rc"
assert_contains "[SPEC-11] error names persona.role field (|)" "$err_out" "persona.role"

# ─── SPEC-12: persona.perspective declared as '|-' fails ─────────────────────
MANIFEST="$FIXTURE_DIR/perspective-block-pipe-strip.yaml"
cat > "$MANIFEST" <<'EOF'
id: bad-persp-pipes
name: Bad Perspective Pipe-Strip
kind: persona
version: 0.1.0
persona:
  role: a software architect
  perspective: |-
    Judge structure, boundaries, and coupling.
EOF

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
rc=$?
set -e
assert_eq "[SPEC-12] persona.perspective declared as '|-' fails validation" "1" "$rc"
assert_contains "[SPEC-12] error names persona.perspective field (|-)" "$err_out" "persona.perspective"

# ─── SPEC-13: persona.role declared as '>+' fails (keep-chomping variant) ────
MANIFEST="$FIXTURE_DIR/role-block-gt-keep.yaml"
cat > "$MANIFEST" <<'EOF'
id: bad-role-gtk
name: Bad Role GT-Keep
kind: persona
version: 0.1.0
persona:
  role: >+
    A software architect who thinks in systems.
  perspective: Structure and boundaries.
EOF

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
rc=$?
set -e
assert_eq "[SPEC-13] persona.role declared as '>+' fails validation" "1" "$rc"
assert_contains "[SPEC-13] error names persona.role field (>+)" "$err_out" "persona.role"

# ─── SPEC-14: persona.perspective declared as '|+' fails (keep-chomping) ─────
MANIFEST="$FIXTURE_DIR/perspective-block-pipe-keep.yaml"
cat > "$MANIFEST" <<'EOF'
id: bad-persp-pipek
name: Bad Perspective Pipe-Keep
kind: persona
version: 0.1.0
persona:
  role: a software architect
  perspective: |+
    Judge structure, boundaries, and coupling.
EOF

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
rc=$?
set -e
assert_eq "[SPEC-14] persona.perspective declared as '|+' fails validation" "1" "$rc"
assert_contains "[SPEC-14] error names persona.perspective field (|+)" "$err_out" "persona.perspective"

# ─── SPEC-15..SPEC-17: guard assertions for the live red-team manifest ────────
REAL_MANIFEST="$REPO_ROOT/plugins/persona/red-team/manifest.yaml"

# SPEC-15: live red-team manifest passes validate_manifest (guard — must not regress)
set +e
validate_manifest "$REAL_MANIFEST" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-15] live red-team manifest passes validate_manifest" "0" "$rc"

# SPEC-16: red-team manifest declares kind:persona (guard)
rt_kind="$(yaml_get "$REAL_MANIFEST" "kind" 2>/dev/null || true)"
assert_eq "[SPEC-16] live red-team manifest declares kind:persona" "persona" "$rt_kind"

# SPEC-17: red-team manifest has a non-empty persona.role (guard)
rt_role="$(yaml_get "$REAL_MANIFEST" "persona.role" 2>/dev/null || true)"
[[ -n "$rt_role" ]] && rt_role_present=1 || rt_role_present=0
assert_eq "[SPEC-17] live red-team manifest has a non-empty persona.role" "1" "$rt_role_present"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
