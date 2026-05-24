#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  vercel-deploy.sh — Deploy adapter for Vercel                           ║
# ║                                                                          ║
# ║  Sourced by shipwright init --deploy to generate platform-specific commands.   ║
# ║  Exports: staging_cmd, production_cmd, rollback_cmd, detect_platform    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

adapter_name="vercel"

detect_platform() {
    # Vercel: look for vercel.json or .vercel/ directory
    [[ -f "vercel.json" ]] || [[ -d ".vercel" ]]
}

get_staging_cmd() {
    echo "vercel deploy --yes 2>&1 | tee .claude/pipeline-artifacts/deploy-staging.log"
}

get_production_cmd() {
    echo "vercel deploy --prod --yes 2>&1 | tee .claude/pipeline-artifacts/deploy-prod.log"
}

get_rollback_cmd() {
    echo "vercel rollback --yes"
}

get_health_url() {
    # Vercel provides a preview URL from the deploy output
    echo ""
}

get_smoke_cmd() {
    echo "curl -sf \$(vercel ls --json 2>/dev/null | jq -r '.[0].url // empty') > /dev/null"
}
