#!/usr/bin/env bash
# Integration test (#798, ADR-028): _llm_envelope_parse and artifact-render.sh's
# _artifact_split_prose_json MUST produce byte-identical splits for the same
# input. The framework's parser is a thin wrapper over the same underlying
# extract_json_and_surrounding_prose; renderer interop is the regression guard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"
emit_event() { return 0; }
# shellcheck source=../../scripts/lib/llm-agent.sh
source "$REPO_ROOT/scripts/lib/llm-agent.sh"

print_test_header "llm-agent envelope_parse vs artifact-render split byte-equivalence (#798)"

_compare() {
    local label="$1" input="$2"
    # Framework parse:
    local fjson="" fprose=""
    _llm_envelope_parse "$input" fjson fprose
    # Renderer split:
    local rprose="" rjson=""
    _artifact_split_prose_json "$input" rprose rjson
    assert_eq "$label: json byte-identical" "$fjson" "$rjson"
    assert_eq "$label: prose byte-identical" "$fprose" "$rprose"
}

# Case A: clean JSON
_compare "A clean JSON" '{"verdict":"pass","schema_version":1}'

# Case B: prose-prefixed
_compare "B prose-prefix" 'Based on my analysis:

{"verdict":"complete","missing":[]}'

# Case C: fence-wrapped (#510)
_compare "C json fence" '```json
{"v":1}
```'

# Case D: prose-around-fence (#510 contract violation case)
_compare "D prose around fence" 'Based on my analysis,

```json
{"verdict":"complete"}
```

That is the verdict.'

# Case E: empty input
_compare "E empty" ""

# Case F: prose-only (no JSON)
_compare "F prose only" 'Just some text, no JSON envelope here.'

print_test_results
exit $((FAIL > 0))
