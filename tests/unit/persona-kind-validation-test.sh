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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
