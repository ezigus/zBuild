# architecture.sh — Gather call-graph and dependency context for plan/design stages
# Source from pipeline-stages. Requires compat (detect_primary_language).
[[ -n "${_ARCHITECTURE_CONTEXT_LOADED:-}" ]] && return 0
_ARCHITECTURE_CONTEXT_LOADED=1

# Gather rich architecture context: structure, imports, modules, entry points, test map
gather_architecture_context() {
    local repo_root="${1:-.}"
    local context=""

    # 1. File structure
    context="## Project Structure
$(find "$repo_root" -type f \( -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.sh' -o -name '*.go' -o -name '*.rs' \) 2>/dev/null | grep -v node_modules | grep -v .git | head -100 | sort)

"

    # 2. Import/dependency graph (language-specific)
    local lang=""
    if type detect_primary_language >/dev/null 2>&1; then
        lang=$(detect_primary_language "$repo_root" 2>/dev/null || echo "unknown")
    else
        lang="unknown"
    fi

    case "$lang" in
        typescript|javascript|nodejs)
            context="${context}## Import Graph (Top Dependencies)
"
            local imports=""
            for dir in "$repo_root/src" "$repo_root/lib" "$repo_root/app"; do
                [[ -d "$dir" ]] || continue
                imports=$(grep -rh "^import .* from\|require(" "$dir" 2>/dev/null | \
                    grep -oE "from ['\"]([^'\"]+)['\"]|require\\(['\"]([^'\"]+)['\"]\\)" | \
                    sed "s/from ['\"]//;s/['\"]//g;s/require(//;s/)//g" | \
                    sort | uniq -c | sort -rn | head -20)
                [[ -n "$imports" ]] && context="${context}${imports}
"
            done
            [[ -z "$imports" ]] && context="${context}(none detected)
"

            context="${context}## Module Export Counts
"
            local f
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                local exports=0
                exports=$(grep -c "^export " "$f" 2>/dev/null || true)
                exports="${exports:-0}"
                [[ "$exports" -gt 2 ]] 2>/dev/null && context="${context}  $(basename "$f"): $exports exports
"
            done < <(find "$repo_root/src" "$repo_root/lib" -name "*.ts" -o -name "*.js" 2>/dev/null | head -30)
            ;;

        python)
            context="${context}## Import Graph (Top Dependencies)
"
            local py_imports=""
            py_imports=$(find "$repo_root" -name "*.py" -type f 2>/dev/null | \
                xargs grep -h "^from \|^import " 2>/dev/null | \
                grep -v __pycache__ | sort | uniq -c | sort -rn | head -20)
            context="${context}${py_imports}
"
            ;;

        bash|shell)
            context="${context}## Source Dependencies
"
            local sh_imports=""
            [[ -d "$repo_root/scripts" ]] && \
                sh_imports=$(grep -rh "^source \|^\. " "$repo_root/scripts" --include="*.sh" 2>/dev/null | \
                    sort | uniq -c | sort -rn | head -20)
            context="${context}${sh_imports}
"
            ;;
        *)
            context="${context}## Dependencies
(Language: $lang — no specific import analysis)
"
            ;;
    esac

    # 3. Module boundaries (directories with >2 files = modules)
    context="${context}## Module Boundaries
"
    local dir
    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        local count=0
        count=$(find "$dir" -maxdepth 1 -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.sh" \) 2>/dev/null | wc -l | tr -d ' ')
        [[ "$count" -gt 2 ]] 2>/dev/null && context="${context}  $(basename "$dir")/: $count files
"
    done < <(find "$repo_root/src" "$repo_root/lib" "$repo_root/scripts" -maxdepth 2 -type d 2>/dev/null | head -30)

    # 4. Entry points
    context="${context}## Entry Points
"
    if [[ -f "$repo_root/package.json" ]] && command -v jq >/dev/null 2>&1; then
        local main
        main=$(jq -r '.main // .bin // "index.js" | if type == "object" then (. | keys[0]) else . end' "$repo_root/package.json" 2>/dev/null || echo "")
        [[ -n "$main" && "$main" != "null" ]] && context="${context}  package.json: $main
"
    fi
    if [[ -f "$repo_root/Makefile" ]]; then
        local targets
        targets=$(grep '^[a-zA-Z][a-zA-Z0-9_-]*:' "$repo_root/Makefile" 2>/dev/null | cut -d: -f1 | head -10 | tr '\n' ', ')
        [[ -n "$targets" ]] && context="${context}  Makefile targets: $targets
"
    fi

    # 5. Test-to-source mapping
    context="${context}## Test Coverage Map
"
    local test_file
    while IFS= read -r test_file; do
        [[ -f "$test_file" ]] || continue
        local base
        base=$(basename "$test_file" | sed 's/[-.]test//;s/[-.]spec//;s/__tests__//;s/\..*$//' | head -c 50)
        [[ -z "$base" ]] && continue
        local source
        source=$(find "$repo_root/src" "$repo_root/lib" "$repo_root/scripts" -name "${base}.*" -type f 2>/dev/null | head -1)
        [[ -n "$source" ]] && context="${context}  $test_file -> $source
"
    done < <(find "$repo_root" -path "*node_modules" -prune -o -path "*/.git" -prune -o \( -name "*test*" -o -name "*spec*" \) -type f -print 2>/dev/null | head -20)

    echo "$context"
}
