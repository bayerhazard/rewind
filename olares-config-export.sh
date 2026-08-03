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
CONFIG_DIR="/Data/${DATE}"

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

    # Kategorie-Auswahl (Env-Vars, Default alle an)
    # EXPORT_APPS_CATEGORY / EXPORT_SYSTEM = 1|0
    # EXPORT_APPS = kommagetrennte App-Liste (leer = alle Apps)
    log "Kategorien: system=${EXPORT_SYSTEM:-1} apps=${EXPORT_APPS_CATEGORY:-1}"
    if [ -n "${EXPORT_APPS:-}" ]; then
        log "Ausgewaehlte Apps: ${EXPORT_APPS}"
    fi

    if $DRY_RUN; then
        log "DRY-RUN mode — no files will be written"
    fi

    health_check

    # --- System-Kategorie ---
    if [ "${EXPORT_SYSTEM:-1}" = "1" ]; then
        # --- Integration Accounts ---
        log ""
        log "Integration accounts..."
        local integration_accounts
        integration_accounts=$(run_cmd "integration" settings integration accounts list)
        save_json "${CONFIG_DIR}/integration/accounts.json" "$integration_accounts" "ok"

        # --- Users ---
        log ""
        log "Users..."
        local users_me
        users_me=$(run_cmd "users-me" settings users me)
        save_json "${CONFIG_DIR}/users/role.json" "$users_me" "ok"

        # --- User-Profil (Anzeigename, Beschreibung, Avatar) ---
        log ""
        log "User profile..."
        local profile_data
        profile_data=$(run_cmd "user-profile" settings users list)
        save_json "${CONFIG_DIR}/profile/users.json" "$profile_data" "ok"

        # Avatar-Datei herunterladen (URL aus users.json, öffentlich auslieferbar)
        local avatar_url
        avatar_url=$(echo "$profile_data" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list) and data:
        print(data[0].get('avatar', ''))
except:
    pass
" 2>/dev/null)
        if [ -n "$avatar_url" ] && ! $DRY_RUN; then
            mkdir -p "${CONFIG_DIR}/profile"
            if python3 -c "
import urllib.request, sys
try:
    urllib.request.urlretrieve('$avatar_url', '${CONFIG_DIR}/profile/avatar.png')
    print('ok')
except Exception as e:
    print('err', e)
" 2>/dev/null | grep -q ok; then
                log_ok "Avatar gespeichert"
            else
                log_warn "Avatar konnte nicht geladen werden"
            fi
        fi

        # --- Appearance ---
        log ""
        log "Appearance..."
        local appearance
        appearance=$(run_cmd "appearance" settings appearance get)
        save_json "${CONFIG_DIR}/appearance.json" "$appearance" "ok"

        # --- Video ---
        log ""
        log "Video settings..."
        local video
        video=$(run_cmd "video" settings video get 2>/dev/null || echo '{"status": "unavailable"}')
        save_json "${CONFIG_DIR}/video/settings.json" "$video" "ok"

        # --- Backup Plans ---
        log ""
        log "Backup plans..."
        local backup_plans
        backup_plans=$(run_cmd "backup-plans" settings backup plans list)
        save_json "${CONFIG_DIR}/backup/plans.json" "$backup_plans" "ok"

        # --- Restore Plans ---
        log ""
        log "Restore plans..."
        local restore_plans
        restore_plans=$(run_cmd "restore-plans" settings restore plans list 2>/dev/null || echo '{"status": "unavailable"}')
        save_json "${CONFIG_DIR}/restore/plans.json" "$restore_plans" "ok"
    fi


    # --- App-Einstellungen ---
    if [ "${EXPORT_APPS_CATEGORY:-1}" = "1" ]; then
        log ""
        log "App settings (installed apps)..."
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

                if [ -n "${EXPORT_APPS:-}" ]; then
                    local app_selected=""
                    local sel
                    for sel in ${EXPORT_APPS//,/ }; do
                        if [ "$sel" = "$app" ]; then app_selected="1"; break; fi
                    done
                    [ -z "$app_selected" ] && continue
                fi

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
    fi

    # --- Manifest ---
    log ""
    log "Creating manifest..."
    if ! $DRY_RUN; then
        python3 << INNERPY 2>/dev/null || log_warn "Manifest creation failed"
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
INNERPY
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
