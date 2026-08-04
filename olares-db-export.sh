#!/bin/bash
# =============================================================================
# Rewind DB-Export — pg_dump für DB-gestützte Apps (Citus/Postgres)
# =============================================================================
# Sichert die Datenbanken von Apps wie LiteLLM, die ihre Daten NICHT in
# Settings/Dateien, sondern in der Olares-Citus-Postgres ablegen.
#
# Credentials: REWIND_DB_DSN  (kommagetrennte postgresql://-URIs, z.B.
#   postgresql://litellm:PASS@citus-master-svc.user-system-aimighty:5432/litellm)
#   Die URI entspricht dem DATABASE_URL-Secret der jeweiligen App.
#
# Ziel: /Data/<datum>/db/<dbname>.sql.gz  (vom Olares "Backup Data"-Plan erfasst)
# Ohne gesetzten DSN wird der Schritt übersprungen (kein Fehler).
# =============================================================================

set -uo pipefail

DATE="${EXPORT_DATE:-$(date +%Y-%m-%d)}"
DB_DIR="/Data/${DATE}/db"

log()    { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK: $*"; }
log_warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }
log_err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

if [ -z "${REWIND_DB_DSN:-}" ]; then
    log_warn "REWIND_DB_DSN nicht gesetzt — DB-Export übersprungen."
    log_warn "DB-gestützte Apps (z.B. LiteLLM) sind damit NICHT als Datenbank gesichert."
    exit 0
fi

if ! command -v pg_dump >/dev/null 2>&1; then
    log_err "pg_dump nicht im Image vorhanden — DB-Export nicht möglich."
    exit 1
fi

mkdir -p "$DB_DIR"

success_count=0
fail_count=0
IFS=',' read -ra DSNS <<< "$REWIND_DB_DSN"
for dsn in "${DSNS[@]}"; do
    dsn="$(echo "$dsn" | xargs)"
    [ -z "$dsn" ] && continue

    # Datenbankname aus der URI extrahieren: postgresql://user:pw@host:port/db?x
    db="$(echo "$dsn" | sed -E 's|.*/([^/?]+)(\?.*)?$|\1|')"
    [ -z "$db" ] && { log_err "Kann Datenbanknamen aus '$dsn' nicht ermitteln"; fail_count=$((fail_count+1)); continue; }

    # sslmode normalisieren (Citus hat i.d.R. kein TLS auf dem Cluster-Port;
    # verhindert "invalid response to SSL negotiation")
    case "$dsn" in
      *sslmode=*) ;;
      *\?*) dsn="${dsn}&sslmode=disable" ;;
      *)    dsn="${dsn}?sslmode=disable" ;;
    esac

    log "pg_dump '$db' -> $DB_DIR/$db.sql.gz"
    if pg_dump "$dsn" -Z 6 -f "$DB_DIR/$db.sql.gz" 2>/tmp/pgdump.err; then
        log_ok "$db: $(du -h "$DB_DIR/$db.sql.gz" | cut -f1)"
        success_count=$((success_count+1))
    else
        log_err "$db: pg_dump fehlgeschlagen: $(tail -1 /tmp/pgdump.err)"
        rm -f "$DB_DIR/$db.sql.gz"
        fail_count=$((fail_count+1))
    fi
done

log "DB-Export fertig: $success_count ok, $fail_count fehlgeschlagen."
[ "$fail_count" -eq 0 ] || exit 1
exit 0
