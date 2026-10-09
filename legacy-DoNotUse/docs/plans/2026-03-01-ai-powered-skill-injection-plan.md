# AI-Powered Skill Injection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace static rules-based skill selection with LLM-powered intelligent routing, dynamic skill generation, and outcome learning.

**Architecture:** One haiku LLM call at intake analyzes the issue and returns a complete skill plan (selection + rationale + generated skills). Downstream stages read from the plan artifact. A second haiku call at completion analyzes outcomes and refines the skill library. Static registry remains as three-layer fallback.

**Tech Stack:** Bash, jq, Claude CLI (haiku model via `_intelligence_call_claude()`), JSON artifacts

---

### Task 1: Create Generated Skills Directory Structure

**Files:**
- Create: `scripts/skills/generated/.gitkeep`
- Create: `scripts/skills/generated/_refinements/.gitkeep`

**Step 1: Create directories**

```bash
mkdir -p scripts/skills/generated/_refinements
touch scripts/skills/generated/.gitkeep
touch scripts/skills/generated/_refinements/.gitkeep
```

**Step 2: Commit**

```bash
git add scripts/skills/generated/
git commit -m "chore: add generated skills directory structure"
```

---

### Task 2: Add `skill_build_catalog()` to skill-registry.sh

**Files:**
- Modify: `scripts/lib/skill-registry.sh` (append after line 319)
- Test: `scripts/test-skill-injection.sh`

**Step 1: Write the failing test**

Add Suite 11 to `scripts/test-skill-injection.sh`:

```bash
echo ""
echo "═══ Suite 11: Skill Catalog Builder ═══"
echo ""

# Test: catalog includes curated skills
echo "  ── Curated skills in catalog ──"
local catalog
catalog=$(skill_build_catalog 2>/dev/null || true)
assert_contains "$catalog" "brainstorming" "catalog includes brainstorming"
assert_contains "$catalog" "frontend-design" "catalog includes frontend-design"
assert_contains "$catalog" "security-audit" "catalog includes security-audit"

# Test: catalog includes one-line descriptions
assert_contains "$catalog" "Socratic" "brainstorming has description"

# Test: catalog includes generated skills when they exist
local _gen_dir="${SKILLS_DIR}/generated"
mkdir -p "$_gen_dir"
echo "## Test Generated Skill\nTest content for generated skill." > "$_gen_dir/test-gen-skill.md"
catalog=$(skill_build_catalog 2>/dev/null || true)
assert_contains "$catalog" "test-gen-skill" "catalog includes generated skill"
assert_contains "$catalog" "[generated]" "generated skill is tagged"
rm -f "$_gen_dir/test-gen-skill.md"

# Test: catalog includes memory context when available
skill_memory_clear 2>/dev/null || true
skill_memory_record "frontend" "plan" "brainstorming" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "frontend" "plan" "brainstorming" "success" "1" >/dev/null 2>&1 || true
catalog=$(skill_build_catalog "frontend" "plan" 2>/dev/null || true)
assert_contains "$catalog" "success" "catalog includes memory context"
skill_memory_clear 2>/dev/null || true
```

**Step 2: Run test to verify it fails**

Run: `bash scripts/test-skill-injection.sh 2>&1 | grep -A2 "Suite 11"`
Expected: FAIL — `skill_build_catalog: command not found`

**Step 3: Write the implementation**

Append to `scripts/lib/skill-registry.sh` after line 319:

```bash
# ─────────────────────────────────────────────────────────────────────────────
# AI-POWERED SKILL SELECTION (Tier 1)
# ─────────────────────────────────────────────────────────────────────────────

GENERATED_SKILLS_DIR="${SKILLS_DIR}/generated"
REFINEMENTS_DIR="${GENERATED_SKILLS_DIR}/_refinements"

# skill_build_catalog — Build a compact skill index for the LLM router prompt.
#   $1: issue_type (optional — for memory context)
#   $2: stage (optional — for memory context)
# Returns: multi-line text, one skill per line with description and optional memory stats.
skill_build_catalog() {
    local issue_type="${1:-}" stage="${2:-}"
    local catalog=""

    # Scan curated skills
    local skill_file
    for skill_file in "$SKILLS_DIR"/*.md; do
        [[ ! -f "$skill_file" ]] && continue
        local name
        name=$(basename "$skill_file" .md)
        # Extract first meaningful line as description (skip headers, blank lines)
        local desc
        desc=$(grep -v '^#\|^$\|^---\|^\*\*IMPORTANT' "$skill_file" 2>/dev/null | head -1 | cut -c1-120 || echo "")
        [[ -z "$desc" ]] && desc=$(head -1 "$skill_file" | sed 's/^#* *//' | cut -c1-120)

        local memory_hint=""
        if [[ -n "$issue_type" && -n "$stage" ]] && type skill_memory_get_success_rate >/dev/null 2>&1; then
            local rate
            rate=$(skill_memory_get_success_rate "$issue_type" "$stage" "$name" 2>/dev/null || true)
            [[ -n "$rate" ]] && memory_hint=" [${rate}% success for ${issue_type}/${stage}]"
        fi

        catalog="${catalog}
- ${name}: ${desc}${memory_hint}"
    done

    # Scan generated skills
    if [[ -d "$GENERATED_SKILLS_DIR" ]]; then
        for skill_file in "$GENERATED_SKILLS_DIR"/*.md; do
            [[ ! -f "$skill_file" ]] && continue
            local name
            name=$(basename "$skill_file" .md)
            local desc
            desc=$(grep -v '^#\|^$\|^---\|^\*\*IMPORTANT' "$skill_file" 2>/dev/null | head -1 | cut -c1-120 || echo "")
            [[ -z "$desc" ]] && desc=$(head -1 "$skill_file" | sed 's/^#* *//' | cut -c1-120)

            local memory_hint=""
            if [[ -n "$issue_type" && -n "$stage" ]] && type skill_memory_get_success_rate >/dev/null 2>&1; then
                local rate
                rate=$(skill_memory_get_success_rate "$issue_type" "$stage" "$name" 2>/dev/null || true)
                [[ -n "$rate" ]] && memory_hint=" [${rate}% success for ${issue_type}/${stage}]"
            fi

            catalog="${catalog}
- ${name} [generated]: ${desc}${memory_hint}"
        done
    fi

    echo "$catalog"
}
```

**Step 4: Run test to verify it passes**

Run: `bash scripts/test-skill-injection.sh 2>&1 | tail -5`
Expected: ALL TESTS PASSED

**Step 5: Commit**

```bash
git add scripts/lib/skill-registry.sh scripts/test-skill-injection.sh
git commit -m "feat(skills): add skill_build_catalog for LLM router prompt"
```

---

### Task 3: Add `skill_analyze_issue()` — the LLM Router

**Files:**
- Modify: `scripts/lib/skill-registry.sh` (append after `skill_build_catalog`)
- Test: `scripts/test-skill-injection.sh`

**Step 1: Write the failing test**

Add to Suite 11 in `scripts/test-skill-injection.sh`:

```bash
echo ""
echo "  ── LLM skill analysis (mock) ──"

# We can't test real LLM calls in unit tests, so test the JSON parsing/artifact writing
# Mock: simulate skill_analyze_issue writing skill-plan.json
local _test_artifacts
_test_artifacts=$(mktemp -d)

local _mock_plan='{"issue_type":"frontend","confidence":0.92,"secondary_domains":["accessibility"],"complexity_assessment":{"score":6,"reasoning":"moderate"},"skill_plan":{"plan":["brainstorming","frontend-design"],"build":["frontend-design"],"review":["two-stage-review"]},"skill_rationale":{"frontend-design":"ARIA progressbar needed","brainstorming":"Task decomposition required"},"generated_skills":[],"review_focus":["accessibility"],"risk_areas":["ETA accuracy"]}'
echo "$_mock_plan" > "$_test_artifacts/skill-plan.json"

# Verify skill-plan.json is valid JSON
assert_true "jq '.' '$_test_artifacts/skill-plan.json' >/dev/null 2>&1" "skill-plan.json is valid JSON"

# Verify we can extract skills for a stage
local _plan_skills
_plan_skills=$(jq -r '.skill_plan.plan[]' "$_test_artifacts/skill-plan.json" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
assert_eq "$_plan_skills" "brainstorming,frontend-design" "plan stage skills extracted correctly"

# Verify rationale extraction
local _rationale
_rationale=$(jq -r '.skill_rationale["frontend-design"]' "$_test_artifacts/skill-plan.json" 2>/dev/null)
assert_contains "$_rationale" "ARIA" "rationale extracted correctly"

rm -rf "$_test_artifacts"
```

**Step 2: Run test to verify it fails**

Run: `bash scripts/test-skill-injection.sh 2>&1 | grep "LLM skill analysis"`
Expected: Tests should pass (testing JSON parsing, not LLM call)

**Step 3: Write the implementation**

Append to `scripts/lib/skill-registry.sh`:

```bash
# skill_analyze_issue — LLM-powered skill selection and gap detection.
#   $1: issue_title
#   $2: issue_body
#   $3: issue_labels
#   $4: artifacts_dir (where to write skill-plan.json)
#   $5: intelligence_json (optional — reuse from intelligence_analyze_issue)
# Returns: 0 on success (skill-plan.json written), 1 on failure (caller should fallback)
# Requires: _intelligence_call_claude() from sw-intelligence.sh
skill_analyze_issue() {
    local title="${1:-}" body="${2:-}" labels="${3:-}"
    local artifacts_dir="${4:-${ARTIFACTS_DIR:-.claude/pipeline-artifacts}}"
    local intelligence_json="${5:-}"

    # Verify we have the LLM call function
    if ! type _intelligence_call_claude >/dev/null 2>&1; then
        return 1
    fi

    # Build the skill catalog
    local catalog
    catalog=$(skill_build_catalog "" "" 2>/dev/null || true)
    [[ -z "$catalog" ]] && return 1

    # Build memory recommendations
    local memory_context=""
    if type skill_memory_get_recommendations >/dev/null 2>&1; then
        local recs
        recs=$(skill_memory_get_recommendations "backend" "plan" 2>/dev/null || true)
        [[ -n "$recs" ]] && memory_context="Historical skill performance: $recs"
    fi

    # Build the prompt
    local prompt
    prompt="You are a pipeline skill router. Analyze this GitHub issue and select the best skills for each pipeline stage.

## Issue
Title: ${title}
Labels: ${labels}
Body:
${body}

## Available Skills
${catalog}

${memory_context:+## Historical Context
$memory_context
}
${intelligence_json:+## Intelligence Analysis
$intelligence_json
}
## Pipeline Stages
Skills can be assigned to: plan, design, build, review, compound_quality, pr, deploy, validate, monitor

## Instructions
1. Classify the issue type (frontend|backend|api|database|infrastructure|documentation|security|performance|refactor|testing)
2. Select 1-4 skills per stage from the catalog. Only select skills relevant to that stage.
3. For each selected skill, write a one-sentence rationale explaining WHY this skill matters for THIS specific issue (not generic advice).
4. If the issue needs expertise not covered by any existing skill, generate a new skill with focused, actionable content (200-400 words).
5. Identify specific review focus areas and risk areas for this issue.

## Response Format (JSON only, no markdown)
{
  \"issue_type\": \"frontend\",
  \"confidence\": 0.92,
  \"secondary_domains\": [\"accessibility\", \"real-time\"],
  \"complexity_assessment\": {
    \"score\": 6,
    \"reasoning\": \"Brief explanation\"
  },
  \"skill_plan\": {
    \"plan\": [\"skill-name-1\", \"skill-name-2\"],
    \"design\": [\"skill-name\"],
    \"build\": [\"skill-name\"],
    \"review\": [\"skill-name\"],
    \"compound_quality\": [\"skill-name\"],
    \"pr\": [\"skill-name\"],
    \"deploy\": [\"skill-name\"],
    \"validate\": [],
    \"monitor\": []
  },
  \"skill_rationale\": {
    \"skill-name-1\": \"Why this skill matters for this specific issue\",
    \"skill-name-2\": \"Why this skill matters\"
  },
  \"generated_skills\": [
    {
      \"name\": \"new-skill-name\",
      \"reason\": \"Why no existing skill covers this\",
      \"content\": \"## Skill Title\\n\\nActionable guidance...\"
    }
  ],
  \"review_focus\": [\"specific area 1\", \"specific area 2\"],
  \"risk_areas\": [\"specific risk 1\"]
}"

    # Call the LLM
    local cache_key="skill_analysis_$(echo "${title}${body}" | md5sum 2>/dev/null | cut -c1-16 || echo "${RANDOM}")"
    local result
    if ! result=$(_intelligence_call_claude "$prompt" "$cache_key" 3600 "haiku"); then
        return 1
    fi

    # Validate the response has required fields
    local valid
    valid=$(echo "$result" | jq 'has("issue_type") and has("skill_plan") and has("skill_rationale")' 2>/dev/null || echo "false")
    if [[ "$valid" != "true" ]]; then
        warn "Skill analysis returned invalid JSON — falling back to static selection"
        return 1
    fi

    # Write skill-plan.json
    mkdir -p "$artifacts_dir"
    echo "$result" | jq '.' > "$artifacts_dir/skill-plan.json"

    # Save any generated skills to disk
    local gen_count
    gen_count=$(echo "$result" | jq '.generated_skills | length' 2>/dev/null || echo "0")
    if [[ "$gen_count" -gt 0 ]]; then
        mkdir -p "$GENERATED_SKILLS_DIR"
        local i
        for i in $(seq 0 $((gen_count - 1))); do
            local gen_name gen_content
            gen_name=$(echo "$result" | jq -r ".generated_skills[$i].name" 2>/dev/null)
            gen_content=$(echo "$result" | jq -r ".generated_skills[$i].content" 2>/dev/null)
            if [[ -n "$gen_name" && "$gen_name" != "null" && -n "$gen_content" && "$gen_content" != "null" ]]; then
                # Only write if doesn't already exist (don't overwrite improved versions)
                if [[ ! -f "$GENERATED_SKILLS_DIR/${gen_name}.md" ]]; then
                    printf '%b\n' "$gen_content" > "$GENERATED_SKILLS_DIR/${gen_name}.md"
                    info "Generated new skill: ${gen_name}"
                fi
            fi
        done
    fi

    # Update INTELLIGENCE_ISSUE_TYPE from analysis
    local analyzed_type
    analyzed_type=$(echo "$result" | jq -r '.issue_type // empty' 2>/dev/null)
    if [[ -n "$analyzed_type" ]]; then
        export INTELLIGENCE_ISSUE_TYPE="$analyzed_type"
    fi

    # Update INTELLIGENCE_COMPLEXITY from analysis
    local analyzed_complexity
    analyzed_complexity=$(echo "$result" | jq -r '.complexity_assessment.score // empty' 2>/dev/null)
    if [[ -n "$analyzed_complexity" ]]; then
        export INTELLIGENCE_COMPLEXITY="$analyzed_complexity"
    fi

    return 0
}
```

**Step 4: Run tests**

Run: `bash scripts/test-skill-injection.sh 2>&1 | tail -5`
Expected: ALL TESTS PASSED

**Step 5: Commit**

```bash
git add scripts/lib/skill-registry.sh scripts/test-skill-injection.sh
git commit -m "feat(skills): add skill_analyze_issue LLM router"
```

---

### Task 4: Add `skill_load_from_plan()` — Plan-Based Stage Loader

**Files:**
- Modify: `scripts/lib/skill-registry.sh` (append after `skill_analyze_issue`)
- Test: `scripts/test-skill-injection.sh`

**Step 1: Write the failing test**

Add Suite 12 to `scripts/test-skill-injection.sh`:

```bash
echo ""
echo "═══ Suite 12: Plan-Based Skill Loading ═══"
echo ""

local _test_artifacts
_test_artifacts=$(mktemp -d)

# Write a mock skill-plan.json
cat > "$_test_artifacts/skill-plan.json" << 'PLAN_EOF'
{
  "issue_type": "frontend",
  "skill_plan": {
    "plan": ["brainstorming", "frontend-design"],
    "build": ["frontend-design"],
    "review": ["two-stage-review"],
    "deploy": []
  },
  "skill_rationale": {
    "brainstorming": "Task decomposition for progress bar feature",
    "frontend-design": "ARIA progressbar role and responsive CSS needed",
    "two-stage-review": "Spec compliance check against plan.md"
  },
  "generated_skills": []
}
PLAN_EOF

echo "  ── Loading skills from plan ──"

# Test: load plan stage skills
local plan_content
ARTIFACTS_DIR="$_test_artifacts" plan_content=$(skill_load_from_plan "plan" 2>/dev/null || true)
assert_contains "$plan_content" "brainstorming" "plan stage loads brainstorming skill"
assert_contains "$plan_content" "frontend-design" "plan stage loads frontend-design skill content"
assert_contains "$plan_content" "ARIA progressbar" "plan stage includes rationale"
assert_contains "$plan_content" "Task decomposition" "plan stage includes brainstorming rationale"

# Test: load build stage skills
local build_content
ARTIFACTS_DIR="$_test_artifacts" build_content=$(skill_load_from_plan "build" 2>/dev/null || true)
assert_contains "$build_content" "frontend-design" "build stage loads frontend-design"
assert_not_contains "$build_content" "brainstorming" "build stage does NOT load brainstorming"

# Test: empty stage returns empty
local deploy_content
ARTIFACTS_DIR="$_test_artifacts" deploy_content=$(skill_load_from_plan "deploy" 2>/dev/null || true)
assert_eq "" "$(echo "$deploy_content" | tr -d '[:space:]')" "empty stage returns empty"

# Test: missing skill-plan.json falls back to skill_select_adaptive
local _no_plan_dir
_no_plan_dir=$(mktemp -d)
local fallback_content
ARTIFACTS_DIR="$_no_plan_dir" INTELLIGENCE_ISSUE_TYPE="frontend" fallback_content=$(skill_load_from_plan "plan" 2>/dev/null || true)
assert_contains "$fallback_content" "brainstorming\|frontend\|Socratic" "fallback to adaptive when no plan"
rm -rf "$_no_plan_dir"

# Test: refinements are appended
mkdir -p "$SKILLS_DIR/generated/_refinements"
echo "REFINEMENT: Always check stat-bar CSS pattern reuse." > "$SKILLS_DIR/generated/_refinements/frontend-design.patch.md"
ARTIFACTS_DIR="$_test_artifacts" plan_content=$(skill_load_from_plan "plan" 2>/dev/null || true)
assert_contains "$plan_content" "REFINEMENT" "refinement patch appended to skill"
rm -f "$SKILLS_DIR/generated/_refinements/frontend-design.patch.md"

rm -rf "$_test_artifacts"
```

**Step 2: Run test to verify it fails**

Run: `bash scripts/test-skill-injection.sh 2>&1 | grep -A2 "Suite 12"`
Expected: FAIL — `skill_load_from_plan: command not found`

**Step 3: Write the implementation**

Append to `scripts/lib/skill-registry.sh`:

```bash
# skill_load_from_plan — Load skill content for a stage from skill-plan.json artifact.
#   $1: stage (plan|design|build|review|compound_quality|pr|deploy|validate|monitor)
# Reads: $ARTIFACTS_DIR/skill-plan.json
# Returns: combined prompt text with rationale + skill content + refinements.
# Falls back to skill_select_adaptive() if skill-plan.json is missing.
skill_load_from_plan() {
    local stage="${1:-plan}"
    local plan_file="${ARTIFACTS_DIR}/skill-plan.json"

    # Fallback if no plan file
    if [[ ! -f "$plan_file" ]]; then
        if type skill_select_adaptive >/dev/null 2>&1; then
            local _fallback_files _fallback_content
            _fallback_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
            if [[ -n "$_fallback_files" ]]; then
                while IFS= read -r _path; do
                    [[ -z "$_path" || ! -f "$_path" ]] && continue
                    cat "$_path" 2>/dev/null
                done <<< "$_fallback_files"
            fi
        fi
        return 0
    fi

    # Extract skill names for this stage
    local skill_names
    skill_names=$(jq -r ".skill_plan.${stage}[]? // empty" "$plan_file" 2>/dev/null)
    [[ -z "$skill_names" ]] && return 0

    local issue_type
    issue_type=$(jq -r '.issue_type // "unknown"' "$plan_file" 2>/dev/null)

    # Build rationale header
    local rationale_header=""
    rationale_header="### Why these skills were selected (AI-analyzed):
"
    while IFS= read -r skill_name; do
        [[ -z "$skill_name" ]] && continue
        local rat
        rat=$(jq -r ".skill_rationale[\"${skill_name}\"] // empty" "$plan_file" 2>/dev/null)
        [[ -n "$rat" ]] && rationale_header="${rationale_header}- **${skill_name}**: ${rat}
"
    done <<< "$skill_names"

    # Output rationale header
    echo "$rationale_header"

    # Load each skill's content
    while IFS= read -r skill_name; do
        [[ -z "$skill_name" ]] && continue

        local skill_path=""
        # Check curated directory first
        if [[ -f "${SKILLS_DIR}/${skill_name}.md" ]]; then
            skill_path="${SKILLS_DIR}/${skill_name}.md"
        # Then check generated directory
        elif [[ -f "${GENERATED_SKILLS_DIR}/${skill_name}.md" ]]; then
            skill_path="${GENERATED_SKILLS_DIR}/${skill_name}.md"
        fi

        if [[ -n "$skill_path" ]]; then
            cat "$skill_path" 2>/dev/null
            echo ""

            # Append refinement if exists
            local refinement_path="${REFINEMENTS_DIR}/${skill_name}.patch.md"
            if [[ -f "$refinement_path" ]]; then
                echo ""
                cat "$refinement_path" 2>/dev/null
                echo ""
            fi
        fi
    done <<< "$skill_names"
}
```

**Step 4: Run tests**

Run: `bash scripts/test-skill-injection.sh 2>&1 | tail -5`
Expected: ALL TESTS PASSED

**Step 5: Commit**

```bash
git add scripts/lib/skill-registry.sh scripts/test-skill-injection.sh
git commit -m "feat(skills): add skill_load_from_plan for plan-based stage loading"
```

---

### Task 5: Add `skill_analyze_outcome()` — Outcome Learning Loop

**Files:**
- Modify: `scripts/lib/skill-registry.sh` (append after `skill_load_from_plan`)
- Test: `scripts/test-skill-injection.sh`

**Step 1: Write the failing test**

Add Suite 13 to `scripts/test-skill-injection.sh`:

```bash
echo ""
echo "═══ Suite 13: Outcome Learning Loop ═══"
echo ""

local _test_artifacts
_test_artifacts=$(mktemp -d)

# Write a mock skill-plan.json
cat > "$_test_artifacts/skill-plan.json" << 'PLAN_EOF'
{
  "issue_type": "frontend",
  "skill_plan": {
    "plan": ["brainstorming", "frontend-design"],
    "build": ["frontend-design"],
    "review": ["two-stage-review"]
  },
  "skill_rationale": {
    "frontend-design": "ARIA progressbar needed"
  },
  "generated_skills": []
}
PLAN_EOF

echo "  ── Outcome JSON parsing ──"

# Test: parse a mock outcome response
local _mock_outcome='{"skill_effectiveness":{"frontend-design":{"verdict":"effective","evidence":"ARIA section in plan","learning":"stat-bar reuse hint followed"}},"refinements":[{"skill":"frontend-design","addition":"For dashboard features, mention existing CSS patterns"}],"generated_skill_verdict":{}}'
echo "$_mock_outcome" > "$_test_artifacts/skill-outcome.json"

# Verify outcome JSON is valid
assert_true "jq '.' '$_test_artifacts/skill-outcome.json' >/dev/null 2>&1" "outcome JSON is valid"

# Verify verdict extraction
local _verdict
_verdict=$(jq -r '.skill_effectiveness["frontend-design"].verdict' "$_test_artifacts/skill-outcome.json" 2>/dev/null)
assert_eq "effective" "$_verdict" "verdict extracted correctly"

# Verify refinement extraction
local _refinement_skill
_refinement_skill=$(jq -r '.refinements[0].skill' "$_test_artifacts/skill-outcome.json" 2>/dev/null)
assert_eq "frontend-design" "$_refinement_skill" "refinement skill extracted"

echo ""
echo "  ── Refinement file writing ──"

# Test: skill_apply_refinements writes patch files
local _ref_dir="${SKILLS_DIR}/generated/_refinements"
mkdir -p "$_ref_dir"
skill_apply_refinements "$_test_artifacts/skill-outcome.json" 2>/dev/null || true
assert_true "[[ -f '$_ref_dir/frontend-design.patch.md' ]]" "refinement patch file created"
local _ref_content
_ref_content=$(cat "$_ref_dir/frontend-design.patch.md" 2>/dev/null || true)
assert_contains "$_ref_content" "dashboard" "refinement content written"
rm -f "$_ref_dir/frontend-design.patch.md"

echo ""
echo "  ── Generated skill lifecycle ──"

# Test: prune verdict deletes generated skill
mkdir -p "${SKILLS_DIR}/generated"
echo "## Temp Skill" > "${SKILLS_DIR}/generated/temp-skill.md"
local _prune_outcome='{"skill_effectiveness":{},"refinements":[],"generated_skill_verdict":{"temp-skill":"prune"}}'
echo "$_prune_outcome" > "$_test_artifacts/skill-outcome.json"
skill_apply_lifecycle_verdicts "$_test_artifacts/skill-outcome.json" 2>/dev/null || true
assert_true "[[ ! -f '${SKILLS_DIR}/generated/temp-skill.md' ]]" "pruned skill deleted"

rm -rf "$_test_artifacts"
```

**Step 2: Run test to verify it fails**

Run: `bash scripts/test-skill-injection.sh 2>&1 | grep -A2 "Suite 13"`
Expected: FAIL — functions not found

**Step 3: Write the implementation**

Append to `scripts/lib/skill-registry.sh`:

```bash
# skill_analyze_outcome — LLM-powered outcome analysis and learning.
#   $1: pipeline_result ("success" or "failure")
#   $2: artifacts_dir
#   $3: failed_stage (optional — only for failures)
#   $4: error_context (optional — last N lines of error output)
# Reads: $artifacts_dir/skill-plan.json, review artifacts
# Writes: $artifacts_dir/skill-outcome.json, refinement patches, lifecycle verdicts
# Returns: 0 on success, 1 on failure (falls back to boolean recording)
skill_analyze_outcome() {
    local pipeline_result="${1:-success}"
    local artifacts_dir="${2:-${ARTIFACTS_DIR:-.claude/pipeline-artifacts}}"
    local failed_stage="${3:-}"
    local error_context="${4:-}"

    local plan_file="$artifacts_dir/skill-plan.json"
    [[ ! -f "$plan_file" ]] && return 1

    if ! type _intelligence_call_claude >/dev/null 2>&1; then
        return 1
    fi

    # Gather context for analysis
    local skill_plan
    skill_plan=$(cat "$plan_file" 2>/dev/null)

    local review_feedback=""
    [[ -f "$artifacts_dir/review-results.log" ]] && review_feedback=$(tail -50 "$artifacts_dir/review-results.log" 2>/dev/null || true)

    local prompt
    prompt="You are a pipeline learning system. Analyze the outcome of this pipeline run and provide skill effectiveness feedback.

## Skill Plan Used
${skill_plan}

## Pipeline Result: ${pipeline_result}
${failed_stage:+Failed at stage: ${failed_stage}}
${error_context:+Error context:
${error_context}}
${review_feedback:+## Review Feedback
${review_feedback}}

## Instructions
1. For each skill in the plan, assess whether it was effective, partially effective, or ineffective.
2. Provide evidence for each verdict (what in the output shows the skill helped or didn't help).
3. Extract a one-sentence learning that would improve future use of this skill.
4. If any skill content could be improved, provide a specific refinement (one sentence to append).
5. For any generated skills, provide a lifecycle verdict: keep, keep_and_refine, or prune.

## Response Format (JSON only, no markdown)
{
  \"skill_effectiveness\": {
    \"skill-name\": {
      \"verdict\": \"effective|partially_effective|ineffective\",
      \"evidence\": \"What in the output shows this\",
      \"learning\": \"One-sentence takeaway for future runs\"
    }
  },
  \"refinements\": [
    {
      \"skill\": \"skill-name\",
      \"addition\": \"One sentence to append to this skill for future use\"
    }
  ],
  \"generated_skill_verdict\": {
    \"generated-skill-name\": \"keep|keep_and_refine|prune\"
  }
}"

    local cache_key="skill_outcome_$(echo "${skill_plan}${pipeline_result}" | md5sum 2>/dev/null | cut -c1-16 || echo "${RANDOM}")"
    local result
    if ! result=$(_intelligence_call_claude "$prompt" "$cache_key" 3600 "haiku"); then
        return 1
    fi

    # Validate response
    local valid
    valid=$(echo "$result" | jq 'has("skill_effectiveness")' 2>/dev/null || echo "false")
    if [[ "$valid" != "true" ]]; then
        return 1
    fi

    # Write outcome artifact
    echo "$result" | jq '.' > "$artifacts_dir/skill-outcome.json" 2>/dev/null || true

    # Apply refinements
    skill_apply_refinements "$artifacts_dir/skill-outcome.json" 2>/dev/null || true

    # Apply lifecycle verdicts for generated skills
    skill_apply_lifecycle_verdicts "$artifacts_dir/skill-outcome.json" 2>/dev/null || true

    # Record enriched outcomes to skill memory
    local issue_type
    issue_type=$(jq -r '.issue_type // "backend"' "$plan_file" 2>/dev/null)

    echo "$result" | jq -r '.skill_effectiveness | to_entries[] | "\(.key) \(.value.verdict)"' 2>/dev/null | while read -r skill_name verdict; do
        [[ -z "$skill_name" ]] && continue
        local outcome="success"
        [[ "$verdict" == "ineffective" ]] && outcome="failure"
        [[ "$verdict" == "partially_effective" ]] && outcome="retry"

        # Record to all stages this skill was used in
        jq -r ".skill_plan | to_entries[] | select(.value | index(\"$skill_name\")) | .key" "$plan_file" 2>/dev/null | while read -r stage; do
            skill_memory_record "$issue_type" "$stage" "$skill_name" "$outcome" "1" 2>/dev/null || true
        done
    done

    return 0
}

# skill_apply_refinements — Write refinement patches from outcome analysis.
#   $1: path to skill-outcome.json
skill_apply_refinements() {
    local outcome_file="${1:-}"
    [[ ! -f "$outcome_file" ]] && return 1

    mkdir -p "$REFINEMENTS_DIR"

    local ref_count
    ref_count=$(jq '.refinements | length' "$outcome_file" 2>/dev/null || echo "0")
    [[ "$ref_count" -eq 0 ]] && return 0

    local i
    for i in $(seq 0 $((ref_count - 1))); do
        local skill_name addition
        skill_name=$(jq -r ".refinements[$i].skill" "$outcome_file" 2>/dev/null)
        addition=$(jq -r ".refinements[$i].addition" "$outcome_file" 2>/dev/null)
        if [[ -n "$skill_name" && "$skill_name" != "null" && -n "$addition" && "$addition" != "null" ]]; then
            local patch_file="$REFINEMENTS_DIR/${skill_name}.patch.md"
            # Append (don't overwrite) — accumulate learnings
            echo "" >> "$patch_file"
            echo "### Learned ($(date -u +%Y-%m-%d))" >> "$patch_file"
            echo "$addition" >> "$patch_file"
        fi
    done
}

# skill_apply_lifecycle_verdicts — Apply keep/prune verdicts for generated skills.
#   $1: path to skill-outcome.json
skill_apply_lifecycle_verdicts() {
    local outcome_file="${1:-}"
    [[ ! -f "$outcome_file" ]] && return 1

    local verdicts
    verdicts=$(jq -r '.generated_skill_verdict // {} | to_entries[] | "\(.key) \(.value)"' "$outcome_file" 2>/dev/null)
    [[ -z "$verdicts" ]] && return 0

    while read -r skill_name verdict; do
        [[ -z "$skill_name" ]] && continue
        local gen_path="$GENERATED_SKILLS_DIR/${skill_name}.md"

        case "$verdict" in
            prune)
                if [[ -f "$gen_path" ]]; then
                    rm -f "$gen_path"
                    info "Pruned generated skill: ${skill_name}"
                fi
                ;;
            keep)
                # No action needed — skill stays
                ;;
            keep_and_refine)
                # Refinement handled by skill_apply_refinements
                ;;
        esac
    done <<< "$verdicts"
}
```

**Step 4: Run tests**

Run: `bash scripts/test-skill-injection.sh 2>&1 | tail -5`
Expected: ALL TESTS PASSED

**Step 5: Commit**

```bash
git add scripts/lib/skill-registry.sh scripts/test-skill-injection.sh
git commit -m "feat(skills): add outcome learning loop with refinements and lifecycle"
```

---

### Task 6: Integrate into `stage_intake()` in pipeline-stages.sh

**Files:**
- Modify: `scripts/lib/pipeline-stages.sh` (lines 264-296, add after line 288)

**Step 1: Write the integration code**

After the existing label grep block (line 288) and before the `log_stage` call (line 290), add:

```bash
    # 8. AI-powered skill analysis (replaces static classification when available)
    if type skill_analyze_issue >/dev/null 2>&1; then
        local _intel_json=""
        [[ -f "$ARTIFACTS_DIR/intelligence-analysis.json" ]] && _intel_json=$(cat "$ARTIFACTS_DIR/intelligence-analysis.json" 2>/dev/null || true)

        if skill_analyze_issue "$GOAL" "${ISSUE_BODY:-}" "${ISSUE_LABELS:-}" "$ARTIFACTS_DIR" "$_intel_json" 2>/dev/null; then
            info "Skill analysis: AI-powered skill plan written to skill-plan.json"
            # INTELLIGENCE_ISSUE_TYPE and INTELLIGENCE_COMPLEXITY are updated by skill_analyze_issue
        else
            info "Skill analysis: LLM unavailable — using label-based classification"
        fi
    fi
```

**Step 2: Verify the intake flow**

The label grep (lines 264-288) still runs first as a fallback. If `skill_analyze_issue` succeeds, it overwrites `INTELLIGENCE_ISSUE_TYPE` with the LLM's classification. If it fails, the grep-based value stands.

**Step 3: Commit**

```bash
git add scripts/lib/pipeline-stages.sh
git commit -m "feat(intake): integrate AI-powered skill analysis into intake stage"
```

---

### Task 7: Replace `skill_select_adaptive()` calls with `skill_load_from_plan()` in all stages

**Files:**
- Modify: `scripts/lib/pipeline-stages.sh` (plan ~439-469, build ~1309-1326, review ~1762-1789, and similar blocks in design, compound_quality, pr, deploy, validate, monitor)

**Step 1: Replace plan stage injection (lines 439-469)**

Replace the entire `skill_select_adaptive` / `skill_load_prompts` block with:

```bash
    # Inject skill prompts — prefer AI-powered plan, fallback to adaptive
    local _skill_prompts=""
    if type skill_load_from_plan >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_from_plan "plan" 2>/dev/null || true)
    elif type skill_select_adaptive >/dev/null 2>&1; then
        local _skill_files
        _skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "plan" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_skill_files" ]]; then
            _skill_prompts=$(while IFS= read -r _path; do
                [[ -z "$_path" || ! -f "$_path" ]] && continue
                cat "$_path" 2>/dev/null
            done <<< "$_skill_files")
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "plan" 2>/dev/null || true)
    fi
    if [[ -n "$_skill_prompts" ]]; then
        _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
        plan_prompt="${plan_prompt}
## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue, AI-selected)
${_skill_prompts}
"
    fi
```

**Step 2: Apply same pattern to build, design, review, and remaining stages**

Each stage's skill injection block gets the same three-level fallback:
1. `skill_load_from_plan "$stage"` (AI-powered)
2. `skill_select_adaptive` (adaptive rules)
3. `skill_load_prompts` (static registry)

The pattern is identical — only the stage name and variable names change.

**Step 3: Run existing tests**

Run: `bash scripts/test-skill-injection.sh 2>&1 | tail -5`
Expected: ALL TESTS PASSED (existing tests use static functions which still work)

**Step 4: Commit**

```bash
git add scripts/lib/pipeline-stages.sh
git commit -m "feat(stages): replace static skill injection with plan-based loading"
```

---

### Task 8: Integrate `skill_analyze_outcome()` into pipeline completion

**Files:**
- Modify: `scripts/sw-pipeline.sh` (around lines 2494-2555, the completion handler)

**Step 1: Add outcome analysis after the success/failure emit_event blocks**

After line 2543 (end of success block) and before line 2545 (start of failure block), add a shared outcome analysis call. Best location: after the entire if/else block (around line 2560):

```bash
    # AI-powered outcome learning
    if type skill_analyze_outcome >/dev/null 2>&1; then
        local _failed_stage=""
        local _error_ctx=""
        if [[ "$exit_code" -ne 0 ]]; then
            _failed_stage="${CURRENT_STAGE_ID:-unknown}"
            _error_ctx=$(tail -30 "$ARTIFACTS_DIR/errors-collected.json" 2>/dev/null || true)
        fi
        local _outcome_result="success"
        [[ "$exit_code" -ne 0 ]] && _outcome_result="failure"

        if skill_analyze_outcome "$_outcome_result" "$ARTIFACTS_DIR" "$_failed_stage" "$_error_ctx" 2>/dev/null; then
            info "Skill outcome analysis complete — learnings recorded"
        fi
    fi
```

**Step 2: Commit**

```bash
git add scripts/sw-pipeline.sh
git commit -m "feat(pipeline): integrate outcome learning at pipeline completion"
```

---

### Task 9: Upgrade `skill_memory_record()` to store rich verdicts

**Files:**
- Modify: `scripts/lib/skill-memory.sh` (lines 30-91)

**Step 1: Extend the JSON record structure**

Update `skill_memory_record()` to accept optional verdict, evidence, and learning fields:

```bash
# Extended signature:
#   $6: verdict (optional — "effective"|"partially_effective"|"ineffective")
#   $7: evidence (optional — why this verdict)
#   $8: learning (optional — one-sentence takeaway)
```

Update the record JSON construction (line 46-47) to include the new fields:

```bash
    local verdict="${6:-}"
    local evidence="${7:-}"
    local learning="${8:-}"

    local record
    record=$(jq -n \
        --arg it "$issue_type" --arg st "$stage" --arg sk "$skills_used" \
        --arg oc "$outcome" --argjson at "$attempt" --arg ts "$timestamp" \
        --arg vd "$verdict" --arg ev "$evidence" --arg lr "$learning" \
        '{issue_type:$it, stage:$st, skills:$sk, outcome:$oc, attempt:$at, timestamp:$ts, verdict:$vd, evidence:$ev, learning:$lr}')
```

This is backward compatible — existing callers pass 5 args, new fields default to empty strings.

**Step 2: Run tests**

Run: `bash scripts/test-skill-injection.sh 2>&1 | tail -5`
Expected: ALL TESTS PASSED (existing tests pass 5 args, new empty fields are fine)

**Step 3: Commit**

```bash
git add scripts/lib/skill-memory.sh
git commit -m "feat(memory): extend skill_memory_record with verdict/evidence/learning"
```

---

### Task 10: Final Integration Test

**Files:**
- Modify: `scripts/test-skill-injection.sh` (add Suite 14)

**Step 1: Write integration tests**

```bash
echo ""
echo "═══ Suite 14: Full AI Integration ═══"
echo ""

echo "  ── End-to-end skill flow ──"

# Test: catalog → plan → load → outcome cycle
local _e2e_dir
_e2e_dir=$(mktemp -d)

# 1. Build catalog (should include all 17 curated skills)
local _catalog
_catalog=$(skill_build_catalog 2>/dev/null || true)
local _catalog_lines
_catalog_lines=$(echo "$_catalog" | grep -c '^-' 2>/dev/null || echo "0")
assert_true "[[ $_catalog_lines -ge 17 ]]" "catalog has at least 17 skills (got $_catalog_lines)"

# 2. Write a skill plan (simulating what skill_analyze_issue would produce)
cat > "$_e2e_dir/skill-plan.json" << 'E2E_PLAN'
{
  "issue_type": "api",
  "confidence": 0.88,
  "skill_plan": {
    "plan": ["brainstorming", "api-design"],
    "build": ["api-design"],
    "review": ["two-stage-review", "security-audit"]
  },
  "skill_rationale": {
    "api-design": "REST endpoint versioning needed",
    "brainstorming": "Multiple valid API approaches",
    "two-stage-review": "Spec compliance for API contract",
    "security-audit": "Auth endpoint requires security review"
  },
  "generated_skills": []
}
E2E_PLAN

# 3. Load from plan for each stage
local _plan_out _build_out _review_out
ARTIFACTS_DIR="$_e2e_dir" _plan_out=$(skill_load_from_plan "plan" 2>/dev/null || true)
ARTIFACTS_DIR="$_e2e_dir" _build_out=$(skill_load_from_plan "build" 2>/dev/null || true)
ARTIFACTS_DIR="$_e2e_dir" _review_out=$(skill_load_from_plan "review" 2>/dev/null || true)

assert_contains "$_plan_out" "api-design" "plan loads api-design skill"
assert_contains "$_plan_out" "REST endpoint" "plan includes rationale"
assert_contains "$_build_out" "api-design" "build loads api-design"
assert_not_contains "$_build_out" "brainstorming" "build doesn't load plan-only skills"
assert_contains "$_review_out" "two-stage-review" "review loads two-stage-review"
assert_contains "$_review_out" "security-audit" "review loads security-audit"

# 4. Test fallback chain (no plan → adaptive → static)
local _no_plan_dir
_no_plan_dir=$(mktemp -d)
ARTIFACTS_DIR="$_no_plan_dir" INTELLIGENCE_ISSUE_TYPE="api" _plan_out=$(skill_load_from_plan "plan" 2>/dev/null || true)
assert_true "[[ -n '$_plan_out' ]]" "fallback produces output when no plan exists"

# 5. Verify generated skill directory structure
assert_true "[[ -d '$SKILLS_DIR/generated' ]]" "generated skills directory exists"
assert_true "[[ -d '$SKILLS_DIR/generated/_refinements' ]]" "refinements directory exists"

rm -rf "$_e2e_dir" "$_no_plan_dir"
```

**Step 2: Run the full suite**

Run: `bash scripts/test-skill-injection.sh 2>&1 | tail -10`
Expected: ALL TESTS PASSED (count should be ~220+)

**Step 3: Commit**

```bash
git add scripts/test-skill-injection.sh
git commit -m "test(skills): add AI-powered skill injection integration tests"
```

---

## Execution Summary

| Task | What | Files | Depends On |
|---|---|---|---|
| 1 | Directory structure | `scripts/skills/generated/` | — |
| 2 | `skill_build_catalog()` | `skill-registry.sh` | 1 |
| 3 | `skill_analyze_issue()` | `skill-registry.sh` | 2 |
| 4 | `skill_load_from_plan()` | `skill-registry.sh` | 2 |
| 5 | `skill_analyze_outcome()` | `skill-registry.sh` | 2 |
| 6 | Intake integration | `pipeline-stages.sh` | 3 |
| 7 | Stage integration | `pipeline-stages.sh` | 4 |
| 8 | Completion integration | `sw-pipeline.sh` | 5 |
| 9 | Rich memory records | `skill-memory.sh` | 5 |
| 10 | Integration tests | `test-skill-injection.sh` | all |

**Parallelizable:** Tasks 3, 4, 5 are independent (all append to skill-registry.sh but different functions). Tasks 6, 7, 8 are independent (different files). Task 9 is independent.

**Critical path:** 1 → 2 → (3 + 4 + 5) → (6 + 7 + 8 + 9) → 10
