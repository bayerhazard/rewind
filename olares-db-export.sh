#!/bin/bash
# =============================================================================
# Olares Database Export — Supplement to Olares Standard Backup
# =============================================================================
# Exports PostgreSQL database dumps for apps that use the Olares Citus cluster.
# Writes compressed SQL dumps to /Data/Backup/db/ so the Olares "Backup Data"
# plan picks them up automatically.
#
# Usage: ./olares-db-export.sh [--dry-run]
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
DB_DIR="/Data/Backup/db/${DATE}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK: $*"; }
log_warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }
log_err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

# --- Database Discovery -----------------------------------------------------
DEFAULT_DB_APPS=(
    "vaultwarden:vaultwarden"
    "radicale:radicale"
    "n8n:n8n"
    "hermesagent:hermesagent"
    "openwebui:open_webui"
)

discover_databases() {
    local middleware_json
    middleware_json=$(timeout 30 "$OLARES_CLI" cluster middleware list -o json 2>/dev/null) || true
    if [ -n "$middleware_json" ]; then
        echo "$middleware_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict):
                name = item.get('name', item.get('app', ''))
                db = item.get('database', item.get('db', name))
                if name and db:
                    print('{}:{}'.format(name, db))
    elif isinstance(data, dict):
        for key, val in data.items():
            if isinstance(val, dict) and val.get('type') == 'postgresql':
                print('{}:{}'.format(key, val.get('database', key)))
except:
    pass
" 2>/dev/null
    fi
}

DISCOVERED=$(discover_databases)
if [ -n "$DISCOVERED" ]; then
    readarray -t DB_APPS < <(echo "$DISCOVERED")
    readarray -t DB_APPS < <(printf '%s\n' "${DB_APPS[@]}" | sort -u)
else
    DB_APPS=("${DEFAULT_DB_APPS[@]}")
fi

# PostgreSQL Pod Info
PG_POD="citus-0"
PG_NS="os-platform"
PG_USER="olares"
PG_HOST="citus-master-svc.user-system-aimighty"
PG_PORT="5432"

# --- Health Check ------------------------------------------------------------
health_check() {
    log "Health check..."
    if timeout 15 "$OLARES_CLI" settings me whoami &>/dev/null; then
        log_ok "Olares reachable"
    else
        log_err "Olares not reachable — aborting DB export"
        exit 1
    fi
}

# --- Main Export Logic -------------------------------------------------------
main() {
    log "============================================================"
    log "Olares DB Export (Supplement) — ${TIMESTAMP}"
    log "PostgreSQL: ${PG_NS}/${PG_POD} @ ${PG_HOST}:${PG_PORT}"
    log "Databases: ${#DB_APPS[@]}"
    log "Target: ${DB_DIR}"
    log "============================================================"

    if $DRY_RUN; then
        log "DRY-RUN mode — no dumps will be created"
    fi

    health_check
    mkdir -p "$DB_DIR"

    local success_count=0
    local fail_count=0
    local skip_count=0

    for entry in "${DB_APPS[@]}"; do
        IFS=':' read -r app_name db_name <<< "$entry"

        log ""
        log "${app_name} (DB: ${db_name})..."

        if $DRY_RUN; then
            log "DRY-RUN: pg_dump ${db_name} -> ${DB_DIR}/${db_name}.sql.gz"
            skip_count=$((skip_count + 1))
            continue
        fi

        local dump_file="${DB_DIR}/${db_name}.sql.gz"

        # Check if DB exists
        if PGPASSWORD="" kubectl exec -n "$PG_NS" "$PG_POD" -- \
            psql -U "$PG_USER" -h "$PG_HOST" -d postgres -t -A -c \
            "SELECT 1 FROM pg_database WHERE datname='${db_name}';" 2>/dev/null | grep -q "1"; then

            log "  Starting dump..."
            # pg_dump with compression, retry on failure
            local retries=3
            for ((retries=3; retries>=1; retries--)); do
                if kubectl exec -n "$PG_NS" "$PG_POD" -- \
                    bash -c "PGPASSWORD='' pg_dump -U ${PG_USER} -h ${PG_HOST} -d ${db_name} \
                    --no-owner --no-privileges --clean --if-exists --create 2>&1" 2>&1 | \
                    gzip > "$dump_file" 2>/dev/null; then

                    local size
                    size=$(du -h "$dump_file" 2>/dev/null | cut -f1 || echo "?")
                    log_ok "${db_name} dumped (${size})"
                    success_count=$((success_count + 1))
                    break
                fi
                if [ "$retries" -gt 0 ]; then
                    log_warn "  Retry ${retries}/3 for ${db_name}..."
                    sleep 5
                else
                    log_err "${db_name}: pg_dump failed after 3 retries"
                    fail_count=$((fail_count + 1))
                fi
            done
        else
            log_warn "${db_name}: database does not exist"
            echo "-- ${db_name}: database not found at ${TIMESTAMP}" | gzip > "${dump_file}.placeholder"
            skip_count=$((skip_count + 1))
        fi
    done

    # --- Manifest ---
    log ""
    log "Creating manifest..."
    if ! $DRY_RUN; then
        python3 << PYEOF 2>/dev/null || log_warn "Manifest creation failed"
import json, os, glob
target_dir = '${DB_DIR}'
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
    'type': 'database-export-supplement',
    'success': ${success_count},
    'failures': ${fail_count},
    'skipped': ${skip_count},
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
    log "Summary: ${success_count} success, ${fail_count} failed, ${skip_count} skipped"
    log "============================================================"
}

main "$@"
