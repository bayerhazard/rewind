#!/bin/bash
# =============================================================================
# Olares Config Export — Supplement to Olares Standard Backup
# =============================================================================
# Exports settings, integrations, and system configs that Olares standard
# backup does NOT cover. Writes flat JSON files to /Data/Backup/config/
# so the Olares "Backup Data" plan picks them up automatically.
#
# Two-layer architecture:
#   Layer 1: Olares standard backup (file-level: /Data/, /Files/Home/Code/)
#   Layer 2: This script (config-level: settings, DBs, system configs)
#
# Usage: ./olares-config-export.sh [--dry-run]
# =============================================================================

set -euo pipefail

# --- Olares CLI Detection ---------------------------------------------------
detect_olares_path() {
    if command -v olares-cli &>/dev/null; then
        echo "$PATH"
        return
    fi
    local brew_paths=(
        "/home/linuxbrew/.linuxbrew/bin"
        "/home/olares/.linuxbrew/bin"
    )
    local hermes_paths
    hermes_paths=$(find /olares-rootfs -path "*/hermesagent/brew/.linuxbrew/bin" -type d 2>/dev/null | head -1)
    if [ -n "$hermes_paths" ]; then
        echo "$hermes_paths"
        return
    fi
    for p in "${brew_paths[@]}"; do
        if [ -x "$p/olares-cli" ]; then
            echo "$p"
            return
        fi
    done
    local found
    found=$(find / -name "olares-cli" -type f -executable 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "$(dirname "$found")"
        return
    fi
    return 1
}

OLARES_BIN_PATH=$(detect_olares_path) || true
if [ -n "$OLARES_BIN_PATH" ]; then
    export PATH="$OLARES_BIN_PATH:$PATH"
fi

OLARES_CLI="olares-cli"
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S%z)
CONFIG_DIR="/Data/Backup/config/${DATE}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

# --- Helpers -----------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK: $*"; }
log_warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }
log_err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

# Retry wrapper with timeout for olares-cli calls
run_cmd() {
    local label="$1"; shift
    local output retries=3 delay=2 timeout=30
    for ((retries=3; retries>=1; retries--)); do
        if output=$(timeout "$timeout" "$OLARES_CLI" "$@" -o json 2>&1); then
            echo "$output"
            return 0
        fi
        if [ "$retries" -gt 0 ]; then
            log_warn "  Retry ${retries}/3: $label"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    log_err "Failed after 3 retries: $label"
    echo "{\"error\": \"$(echo "$output" | head -1 | tr -d '"')\"}"
    return 1
}

# Save JSON with metadata wrapper
save_json() {
    local filepath="$1"
    local content="$2"
    local status="${3:-ok}"
    local error_msg="${4:-}"

    if $DRY_RUN; then
        log "DRY-RUN: Would write -> $filepath ($status)"
        return 0
    fi

    mkdir -p "$(dirname "$filepath")"

    python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except:
    data = {"raw": sys.argv[1]}
wrapped = {
    "_meta": {
        "exported_at": "'"${TIMESTAMP}"'",
        "status": "'"${status}"'",
        "error": None
    },
    "data": data
}
with open(sys.argv[2], "w") as f:
    json.dump(wrapped, f, indent=2, ensure_ascii=False)
' "$content" "$filepath" 2>/dev/null || {
        # Fallback if python3 fails
        cat > "$filepath" <<FJSON
{
  "_meta": {"exported_at": "${TIMESTAMP}", "status": "${status}"},
  "data_raw": $(echo "$content" | head -c 500 | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo "\"error reading content\"")
}
FJSON
    }
}

# --- Health Check ------------------------------------------------------------
health_check() {
    log "Health check..."
    local whoami
    if whoami=$(timeout 15 "$OLARES_CLI" settings me whoami 2>&1); then
        log_ok "Olares reachable (whoami OK)"
        return 0
    else
        log_err "Olares not reachable — aborting export"
        exit 1
    fi
}

# --- Main Export Logic -------------------------------------------------------
main() {
    log "============================================================"
    log "Olares Config Export (Supplement) — ${TIMESTAMP}"
    log "Target: ${CONFIG_DIR}"
    log "============================================================"

    if $DRY_RUN; then
        log "DRY-RUN mode — no files will be written"
    fi

    health_check

    # --- 1. System Info ---
    log ""
    log "System info..."
    local version_info
    version_info=$(run_cmd "version" settings me version)
    save_json "${CONFIG_DIR}/system/olares-info.json" "$version_info" "ok"

    local me_info
    me_info=$(run_cmd "whoami" settings me whoami)
    save_json "${CONFIG_DIR}/system/whoami.json" "$me_info" "ok"

    # --- 2. Network Configuration (reverse-proxy + overlay) ---
    log "Network configuration..."
    local rp_info
    rp_info=$(run_cmd "reverse-proxy" settings network reverse-proxy get)
    save_json "${CONFIG_DIR}/network/reverse-proxy.json" "$rp_info" "ok"

    local overlay_status
    overlay_status=$(run_cmd "overlay" settings network overlay status)
    save_json "${CONFIG_DIR}/network/overlay.json" "$overlay_status" "ok"

    # --- 3. VPN Configuration (ACL) ---
    log "VPN configuration..."
    local vpn_acl
    vpn_acl=$(run_cmd "vpn-acl" settings vpn acl all)
    save_json "${CONFIG_DIR}/vpn/acl.json" "$vpn_acl" "ok"

    # --- 4. Integration Accounts ---
    log "Integration accounts..."
    local integration_accounts
    integration_accounts=$(run_cmd "integration" settings integration accounts list)
    save_json "${CONFIG_DIR}/integration/accounts.json" "$integration_accounts" "ok"

    # --- 5. Users ---
    log "Users..."
    local users_me
    users_me=$(run_cmd "users-me" settings users me)
    save_json "${CONFIG_DIR}/users/role.json" "$users_me" "ok"

    # --- 6. Appearance ---
    log "Appearance..."
    local appearance
    appearance=$(run_cmd "appearance" settings appearance get)
    save_json "${CONFIG_DIR}/appearance.json" "$appearance" "ok"

    # --- 7. Advanced / Developer ---
    log "Advanced settings..."
    local advanced_env
    advanced_env=$(run_cmd "advanced-env" settings advanced env list 2>/dev/null || echo '{"status": "unavailable"}')
    save_json "${CONFIG_DIR}/advanced/env.json" "$advanced_env" "ok"

    local advanced_containerd
    advanced_containerd=$(run_cmd "advanced-containerd" settings advanced containerd get 2>/dev/null || echo '{"status": "unavailable"}')
    save_json "${CONFIG_DIR}/advanced/containerd.json" "$advanced_containerd" "ok"

    # --- 8. GPU ---
    log "GPU settings..."
    local gpu_mode
    gpu_mode=$(run_cmd "gpu-mode" settings gpu mode get 2>/dev/null || echo '{"status": "unavailable"}')
    save_json "${CONFIG_DIR}/gpu/mode.json" "$gpu_mode" "ok"

    local gpu_apps
    gpu_apps=$(run_cmd "gpu-apps" settings gpu apps list 2>/dev/null || echo '{"status": "unavailable"}')
    save_json "${CONFIG_DIR}/gpu/apps.json" "$gpu_apps" "ok"

    # --- 9. Compute / Accelerator ---
    log "Compute settings..."
    local compute
    compute=$(run_cmd "compute" settings compute list 2>/dev/null || echo '{"status": "unavailable"}')
    save_json "${CONFIG_DIR}/compute/settings.json" "$compute" "ok"

    # --- 10. Video ---
    log "Video settings..."
    local video
    video=$(run_cmd "video" settings video get 2>/dev/null || echo '{"status": "unavailable"}')
    save_json "${CONFIG_DIR}/video/settings.json" "$video" "ok"

    # --- 11. Backup Plans (Olares standard backup config) ---
    log "Backup plans..."
    local backup_plans
    backup_plans=$(run_cmd "backup-plans" settings backup plans list)
    save_json "${CONFIG_DIR}/backup/plans.json" "$backup_plans" "ok"

    # --- 12. Restore Plans ---
    log "Restore plans..."
    local restore_plans
    restore_plans=$(run_cmd "restore-plans" settings restore plans list 2>/dev/null || echo '{"status": "unavailable"}')
    save_json "${CONFIG_DIR}/restore/plans.json" "$restore_plans" "ok"

    # --- 13. App Settings (all installed apps) ---
    log "App settings (all installed apps)..."
    local apps_json
    apps_json=$(run_cmd "market-list" market list --mine)

    local app_names
    app_names=$(echo "$apps_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for app in data:
            print(app.get('name', ''))
    elif isinstance(data, dict) and 'backups' in data:
        pass
    elif 'items' in data:
        for app in data['items']:
            print(app.get('raw', {}).get('app', app.get('display', {}).get('app', '')))
except:
    pass
" 2>/dev/null || echo "")

    if [ -z "$app_names" ]; then
        log_warn "Could not list apps"
    else
        local app_count=0
        while IFS= read -r app; do
            [ -z "$app" ] && continue
            [[ "$app" == *"-shared" ]] && continue

            local app_dir="${CONFIG_DIR}/apps/${app}"
            if ! $DRY_RUN; then
                mkdir -p "$app_dir"
            fi

            local env_data
            if env_data=$(run_cmd "app-env-${app}" settings apps env get "$app" 2>/dev/null); then
                save_json "${app_dir}/env.json" "$env_data" "ok"
            else
                save_json "${app_dir}/env.json" '{}' "ok" "no env data"
            fi

            # Entrances ermitteln
            local entrances_data entrance_names=""
            if entrances_data=$(run_cmd "app-entrances-${app}" settings apps entrances list "$app" 2>/dev/null); then
                save_json "${app_dir}/entrances.json" "$entrances_data" "ok"
                entrance_names=$(echo "$entrances_data" | python3 -c "
import json, sys
try:
    for e in json.load(sys.stdin):
        n = e.get('name', '')
        if n:
            print(n)
except:
    pass
" 2>/dev/null)
            else
                save_json "${app_dir}/entrances.json" '{}' "ok" "no entrances"
            fi

            # Domain + Policy pro Entrance (korrekte CLI-Syntax: <app> <entrance>)
            if [ -z "$entrance_names" ]; then
                save_json "${app_dir}/domain.json" '{"note":"no entrance"}' "ok"
                save_json "${app_dir}/policy.json" '{"note":"no entrance"}' "ok"
            else
                local entrance
                while IFS= read -r entrance; do
                    [ -z "$entrance" ] && continue
                    local domain_data policy_data
                    if domain_data=$(run_cmd "app-domain-${app}-${entrance}" settings apps domain get "$app" "$entrance" 2>/dev/null); then
                        save_json "${app_dir}/domain-${entrance}.json" "$domain_data" "ok"
                    else
                        save_json "${app_dir}/domain-${entrance}.json" '{}' "ok" "no domain"
                    fi
                    if policy_data=$(run_cmd "app-policy-${app}-${entrance}" settings apps policy get "$app" "$entrance" 2>/dev/null); then
                        save_json "${app_dir}/policy-${entrance}.json" "$policy_data" "ok"
                    else
                        save_json "${app_dir}/policy-${entrance}.json" '{}' "ok" "no policy"
                    fi
                done <<< "$entrance_names"
            fi

            app_count=$((app_count + 1))
        done <<< "$app_names"
        log_ok "${app_count} apps exported"
    fi

    # --- Manifest ---
    log ""
    log "Creating manifest..."
    if ! $DRY_RUN; then
        python3 << PYEOF 2>/dev/null || log_warn "Manifest creation failed"
import json, os, glob
target_dir = '${CONFIG_DIR}'
files = []
total_size = 0
for root, dirs, filenames in os.walk(target_dir):
    for fn in sorted(filenames):
        fp = os.path.join(root, fn)
        if os.path.isfile(fp):
            size = os.path.getsize(fp)
            files.append({'path': os.path.relpath(fp, target_dir), 'size': size})
            total_size += size
if total_size > 1048576:
    size_human = '{:.1f} MB'.format(total_size / 1048576)
else:
    size_human = '{:.1f} KB'.format(total_size / 1024)
manifest = {
    'date': '${DATE}',
    'timestamp': '${TIMESTAMP}',
    'type': 'config-export-supplement',
    'total_size': total_size,
    'total_size_human': size_human,
    'files': files
}
with open(os.path.join(target_dir, 'manifest.json'), 'w') as f:
    json.dump(manifest, f, indent=2)
print('Manifest: {} files, {}'.format(len(files), size_human))
PYEOF
    fi

    log ""
    log "============================================================"
    if $DRY_RUN; then
        log "DRY-RUN completed — no files written"
    else
        log_ok "Config export completed -> ${CONFIG_DIR}"
    fi
    log "============================================================"
}

main "$@"
