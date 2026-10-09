#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  fly-deploy.sh — Deploy adapter for Fly.io                             ║
# ║                                                                          ║
# ║  Sourced by shipwright init --deploy to generate platform-specific commands.   ║
# ║  Exports: staging_cmd, production_cmd, rollback_cmd, detect_platform    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

adapter_name="fly"

detect_platform() {
    # Fly.io: look for fly.toml
    [[ -f "fly.toml" ]]
}

get_staging_cmd() {
    echo "fly deploy --strategy canary --wait-timeout 120"
}

get_production_cmd() {
    echo "fly deploy --strategy rolling --wait-timeout 300"
}

get_rollback_cmd() {
    echo "fly releases list --json | jq -r '.[1].version' | xargs -I{} fly deploy --image-ref {}"
}

get_health_url() {
    # Extract app name from fly.toml for health URL
    local app_name
    app_name=$(grep '^app\s*=' fly.toml 2>/dev/null | head -1 | sed 's/.*=\s*"\?\([^"]*\)"\?/\1/' | tr -d ' ')
    if [[ -n "$app_name" ]]; then
        echo "https://${app_name}.fly.dev/health"
    else
        echo ""
    fi
}

get_smoke_cmd() {
    echo "fly status --json | jq -e '.Status == \"running\"'"
}
