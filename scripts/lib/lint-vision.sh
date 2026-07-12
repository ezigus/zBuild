#!/usr/bin/env bash
# lint-vision.sh — CI guard that the repo's OWN vision document (ADR-049 / #1360)
# stays conformant. Kept in the lint tier (not the unit suite) so editing the
# CONTENT of docs/VISION.md never turns unit tests red — but a malformed or
# over-length vision still fails CI here, before it can pre-flight-fail an
# enforce-default dogfood run of zBuild on itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/vision.sh
source "$REPO_ROOT/scripts/lib/vision.sh"

doc="$REPO_ROOT/docs/VISION.md"
if [[ ! -f "$doc" ]]; then
    echo "lint-vision: docs/VISION.md is missing — required for enforce-default runs on zBuild." >&2
    exit 1
fi
if ! validate_vision_doc "$doc"; then
    echo "lint-vision: docs/VISION.md does not conform to ADR-049 (see diagnostics above)." >&2
    exit 1
fi
echo "lint-vision: OK — docs/VISION.md conforms to ADR-049."
