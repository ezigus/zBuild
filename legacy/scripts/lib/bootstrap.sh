#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright bootstrap — Cold-start initialization for optimization data  ║
# ║  Creates sensible defaults when no historical data exists (new installs)  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# bootstrap_optimization — create default iteration model, template weights, model routing
bootstrap_optimization() {
    local opt_dir="$HOME/.shipwright/optimization"
    mkdir -p "$opt_dir"

    # Default iteration model based on common patterns
    if [[ ! -f "$opt_dir/iteration-model.json" ]]; then
        cat > "$opt_dir/iteration-model.json" << 'JSON'
{
    "low": {"mean": 5, "stddev": 2, "samples": 0, "source": "bootstrap"},
    "medium": {"mean": 12, "stddev": 4, "samples": 0, "source": "bootstrap"},
    "high": {"mean": 25, "stddev": 8, "samples": 0, "source": "bootstrap"}
}
JSON
    fi

    # Default template weights
    if [[ ! -f "$opt_dir/template-weights.json" ]]; then
        cat > "$opt_dir/template-weights.json" << 'JSON'
{
    "standard": 1.0,
    "hotfix": 1.0,
    "docs": 1.0,
    "refactor": 1.0,
    "source": "bootstrap"
}
JSON
    fi

    # Default model routing
    if [[ ! -f "$opt_dir/model-routing.json" ]]; then
        cat > "$opt_dir/model-routing.json" << 'JSON'
{
    "routes": {
        "plan": {"recommended": "opus", "source": "bootstrap"},
        "design": {"recommended": "opus", "source": "bootstrap"},
        "build": {"recommended": "sonnet", "source": "bootstrap"},
        "test": {"recommended": "sonnet", "source": "bootstrap"},
        "review": {"recommended": "sonnet", "source": "bootstrap"}
    },
    "default": "sonnet",
    "source": "bootstrap"
}
JSON
    fi
}

# bootstrap_memory — create initial memory patterns based on project type
bootstrap_memory() {
    local mem_dir="$HOME/.shipwright/memory"
    mkdir -p "$mem_dir"

    if [[ ! -f "$mem_dir/patterns.json" ]]; then
        # Detect project type and create initial patterns
        local project_type="unknown"
        [[ -f "package.json" ]] && project_type="nodejs"
        [[ -f "requirements.txt" || -f "pyproject.toml" ]] && project_type="python"
        [[ -f "Cargo.toml" ]] && project_type="rust"
        [[ -f "go.mod" ]] && project_type="go"

        cat > "$mem_dir/patterns.json" << JSON
{
    "project_type": "$project_type",
    "detected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "source": "bootstrap"
}
JSON
    fi
}
