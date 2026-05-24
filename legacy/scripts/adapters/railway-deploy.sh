#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  railway-deploy.sh — Deploy adapter for Railway                         ║
# ║                                                                          ║
# ║  Sourced by shipwright init --deploy to generate platform-specific commands.   ║
# ║  Exports: staging_cmd, production_cmd, rollback_cmd, detect_platform    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

adapter_name="railway"

detect_platform() {
    # Railway: look for railway.toml or .railway/ directory
    [[ -f "railway.toml" ]] || [[ -d ".railway" ]] || [[ -f "railway.json" ]]
}

get_staging_cmd() {
    echo "railway up --environment staging --detach"
}

get_production_cmd() {
    echo "railway up --environment production --detach"
}

get_rollback_cmd() {
    echo "railway rollback --yes"
}

get_health_url() {
    echo ""
}

get_smoke_cmd() {
    echo "railway status --json 2>/dev/null | jq -e '.status == \"running\"'"
}
