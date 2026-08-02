#!/usr/bin/env python3
"""
Rewind — Olares Backup Supplement (Native App)
================================================
Runs directly on Olares One. Serves the web UI and manages
config/DB exports and restores. No SSH proxy needed.

Usage:
    python3 backup-manager.py              # port 8765
    python3 backup-manager.py --port 9999  # custom port
"""

import json
import subprocess
import sys
import os
import argparse
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime, timezone

# --- Config ------------------------------------------------------------------
DEFAULT_PORT = 8765
OLARES_CLI = "olares-cli"
BACKUP_DIR = "/Data/Backup"
CONFIG_DIR = f"{BACKUP_DIR}/config"
DB_DIR = f"{BACKUP_DIR}/db"

last_export = {
    "config": None,
    "db": None,
    "status": "idle"
}
export_lock = threading.Lock()

# --- Helpers -----------------------------------------------------------------
def run_cmd(command, timeout=60):
    try:
        result = subprocess.run(
            command, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return {
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "success": result.returncode == 0
        }
    except subprocess.TimeoutExpired:
        return {"exit_code": -1, "stdout": "", "stderr": "Timeout", "success": False}
    except Exception as e:
        return {"exit_code": -1, "stdout": "", "stderr": str(e), "success": False}

def parse_json(output):
    if not output:
        return None
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return None

# --- Olares Data -------------------------------------------------------------
def get_olares_status():
    commands = {
        "version": f"{OLARES_CLI} settings me version",
        "profile": f"{OLARES_CLI} profile list",
        "network": f"{OLARES_CLI} settings network reverse-proxy get",
        "dashboard": f"{OLARES_CLI} dashboard overview",
    }
    result = {}
    for key, cmd in commands.items():
        r = run_cmd(cmd)
        if r["success"]:
            parsed = parse_json(r["stdout"])
            result[key] = parsed if parsed else r["stdout"].strip()
        else:
            result[key] = {"error": r["stderr"]}
    return result

def get_backup_status():
    result = {}
    r = run_cmd(f"{OLARES_CLI} settings backup plans list -o json")
    if r["success"]:
        plans = parse_json(r["stdout"])
        result["plans"] = plans
    else:
        result["plans"] = {"error": r["stderr"]}

    if plans := result.get("plans", {}).get("backups", []):
        result["snapshots"] = {}
        for plan in plans:
            plan_id = plan.get("id", "")
            plan_name = plan.get("name", "")
            snap_r = run_cmd(f"{OLARES_CLI} settings backup snapshots list {plan_id} --limit 3 -o json")
            if snap_r["success"]:
                snaps = parse_json(snap_r["stdout"])
                result["snapshots"][plan_name] = snaps.get("snapshots", []) if snaps else []
            else:
                result["snapshots"][plan_name] = []
    return result

def get_apps():
    r = run_cmd(f"{OLARES_CLI} market list --mine -o json")
    if r["success"]:
        apps = parse_json(r["stdout"])
        return apps if apps else []
    return []

# --- Export / Supplement Data ------------------------------------------------
def get_export_dates():
    r = run_cmd(f"ls -1d {CONFIG_DIR}/20* 2>/dev/null | xargs -I{{}} basename {{}} | sort -r")
    if r["success"]:
        return [d.strip() for d in r["stdout"].strip().split("\n") if d.strip()]
    return []

def get_db_dates():
    r = run_cmd(f"ls -1d {DB_DIR}/20* 2>/dev/null | xargs -I{{}} basename {{}} | sort -r")
    if r["success"]:
        return [d.strip() for d in r["stdout"].strip().split("\n") if d.strip()]
    return []

def get_manifest(date_str, kind="config"):
    base = CONFIG_DIR if kind == "config" else DB_DIR
    r = run_cmd(f"cat {base}/{date_str}/manifest.json 2>&1")
    if r["success"]:
        return parse_json(r["stdout"])
    return {"error": "Manifest not found"}

def get_export_details(date_str):
    config_manifest = get_manifest(date_str, "config")
    db_manifest = get_manifest(date_str, "db")

    r = run_cmd(f"find {CONFIG_DIR}/{date_str} -type f | head -50 2>&1")
    config_files = r["stdout"].strip().split("\n") if r["success"] else []

    r = run_cmd(f"find {DB_DIR}/{date_str} -type f | head -50 2>&1")
    db_files = r["stdout"].strip().split("\n") if r["success"] else []

    r = run_cmd(f"du -sh {CONFIG_DIR}/{date_str} 2>&1")
    config_size = r["stdout"].strip().split()[0] if r["success"] else "unknown"

    r = run_cmd(f"du -sh {DB_DIR}/{date_str} 2>&1")
    db_size = r["stdout"].strip().split()[0] if r["success"] else "unknown"

    return {
        "date": date_str,
        "config_manifest": config_manifest,
        "db_manifest": db_manifest,
        "config_files": config_files[:50],
        "db_files": db_files[:50],
        "config_size": config_size,
        "db_size": db_size
    }

def trigger_export(kind):
    with export_lock:
        last_export["status"] = "running"

    timestamp = datetime.now().strftime("%Y-%m-%d")
    script = "olares-config-export.sh" if kind == "config" else "olares-db-export.sh"
    cmd = f"bash /app/{script} 2>&1"

    r = run_cmd(cmd, timeout=180)

    with export_lock:
        if r["success"] or "completed" in r["stdout"]:
            last_export[kind] = {
                "timestamp": datetime.now().isoformat(),
                "date": timestamp,
                "status": "success",
                "output": r["stdout"][-500:] if r["stdout"] else ""
            }
            last_export["status"] = "success"
        else:
            last_export[kind] = {
                "timestamp": datetime.now().isoformat(),
                "date": timestamp,
                "status": "error",
                "output": r["stderr"]
            }
            last_export["status"] = "error"

    return last_export[kind]

# --- Restore -----------------------------------------------------------------
def read_export_json(date_str, rel_path):
    r = run_cmd(f"cat {CONFIG_DIR}/{date_str}/{rel_path} 2>&1")
    if r["success"]:
        content = r["stdout"].strip()
        try:
            wrapped = json.loads(content)
            if isinstance(wrapped, dict) and "data" in wrapped:
                content = json.dumps(wrapped["data"])
        except json.JSONDecodeError:
            pass
        return parse_json(content)
    return None

def perform_restore(date_str, dry_run=False):
    log_msg = []
    all_success = True

    log_msg.append(f"Starting restore from export {date_str}...")
    log_msg.append(f"Source: {CONFIG_DIR}/{date_str}")
    log_msg.append("")

    # 1. Verify export exists
    r = run_cmd(f"test -d {CONFIG_DIR}/{date_str} && echo EXISTS || echo MISSING")
    if not r["success"] or "MISSING" in r["stdout"]:
        return {"success": False, "error": f"Export {date_str} not found at {CONFIG_DIR}/", "log": log_msg}

    log_msg.append("Export directory verified.")
    log_msg.append("")

    if dry_run:
        r = run_cmd(f"find {CONFIG_DIR}/{date_str} -name '*.json' | head -30 2>&1")
        if r["success"]:
            log_msg.append("Files that would be restored:")
            for line in r["stdout"].strip().split("\n")[:30]:
                log_msg.append(f"  - {line}")

        r = run_cmd(f"test -d {DB_DIR}/{date_str} && echo EXISTS || echo MISSING")
        if r["success"] and "EXISTS" in r["stdout"]:
            log_msg.append(f"Database dumps found at {DB_DIR}/{date_str}")
            r2 = run_cmd(f"ls {DB_DIR}/{date_str}/*.sql.gz 2>/dev/null")
            if r2["success"]:
                for line in r2["stdout"].strip().split("\n"):
                    log_msg.append(f"  - {os.path.basename(line)}")

        log_msg.append("")
        log_msg.append("[DRY-RUN] No changes made.")
        return {"success": True, "date": date_str, "dry_run": True, "log": "\n".join(log_msg)}

    # 2. Restore App Settings
    log_msg.append("Restoring app settings...")
    r = run_cmd(f"ls {CONFIG_DIR}/{date_str}/apps/ 2>/dev/null")
    if r["success"] and r["stdout"].strip():
        apps = [a.strip() for a in r["stdout"].strip().split("\n") if a.strip()]
        for app in apps:
            env_data = read_export_json(date_str, f"apps/{app}/env.json")
            if env_data and isinstance(env_data, dict):
                vars_to_set = []
                for k, v in env_data.items():
                    if not k.startswith("_"):
                        vars_to_set.append(f'{k}="{v}"')
                if vars_to_set:
                    cmd = f"{OLARES_CLI} settings apps env set {app} " + " ".join(vars_to_set)
                    r = run_cmd(cmd, timeout=30)
                    if r["success"]:
                        log_msg.append(f"  OK: {app} env vars restored")
                    else:
                        log_msg.append(f"  WARN: {app} env vars failed: {r['stderr'][:100]}")

            domain_data = read_export_json(date_str, f"apps/{app}/domain.json")
            if domain_data and isinstance(domain_data, dict):
                third_level = domain_data.get("thirdLevel", domain_data.get("domain", ""))
                if third_level:
                    cmd = f"{OLARES_CLI} settings apps domain set {app} {app} --third-level {third_level}"
                    r = run_cmd(cmd, timeout=15)
                    if r["success"]:
                        log_msg.append(f"  OK: {app} domain restored")
                    else:
                        log_msg.append(f"  WARN: {app} domain failed")

            policy_data = read_export_json(date_str, f"apps/{app}/policy.json")
            if policy_data and isinstance(policy_data, dict):
                auth = policy_data.get("auth", policy_data.get("authentication", "internal"))
                cmd = f"{OLARES_CLI} settings apps policy set {app} --auth {auth}"
                r = run_cmd(cmd, timeout=15)
                if r["success"]:
                    log_msg.append(f"  OK: {app} policy restored")
                else:
                    log_msg.append(f"  WARN: {app} policy failed")
    else:
        log_msg.append("  No app settings found.")

    # 3. Restore Network
    log_msg.append("")
    log_msg.append("Restoring network config...")
    rp_data = read_export_json(date_str, "network/reverse-proxy.json")
    if rp_data and isinstance(rp_data, dict):
        if rp_data.get("enableFrp"):
            cmd = f"{OLARES_CLI} settings network reverse-proxy set --enable-frp"
            r = run_cmd(cmd, timeout=15)
            if r["success"]:
                log_msg.append("  OK: Reverse Proxy (FRP) enabled")
            else:
                log_msg.append(f"  WARN: Reverse Proxy: {r['stderr'][:80]}")

    # 4. Restore VPN
    log_msg.append("")
    log_msg.append("Restoring VPN config...")
    acl_data = read_export_json(date_str, "vpn/acl.json")
    if acl_data and isinstance(acl_data, list):
        for rule in acl_data[:10]:
            app = rule.get("app", "")
            action = rule.get("action", "allow")
            if app:
                cmd = f"{OLARES_CLI} settings vpn acl set --app {app} --action {action}"
                r = run_cmd(cmd, timeout=15)
                if r["success"]:
                    log_msg.append(f"  OK: VPN ACL {app} -> {action}")
                else:
                    log_msg.append(f"  WARN: VPN ACL {app}: {r['stderr'][:60]}")

    # 5. Restore Databases
    log_msg.append("")
    log_msg.append("Restoring databases...")
    r = run_cmd(f"ls {DB_DIR}/{date_str}/*.sql.gz 2>/dev/null")
    if r["success"] and r["stdout"].strip():
        dumps = [d.strip() for d in r["stdout"].strip().split("\n") if d.strip().endswith(".sql.gz")]
        for dump_path in dumps:
            db_name = os.path.basename(dump_path).replace(".sql.gz", "")
            log_msg.append(f"  Restoring {db_name}...")
            cmd = f"""
gunzip -c {dump_path} | \\
kubectl exec -i -n os-platform citus-0 -- \\
psql -U olares -h citus-master-svc.user-system-aimighty -d {db_name} 2>&1
"""
            r = run_cmd(cmd, timeout=180)
            if r["success"] or "ERROR" not in r["stderr"]:
                log_msg.append(f"  OK: {db_name} restored")
            else:
                log_msg.append(f"  ERROR: {db_name} failed: {r['stderr'][:120]}")
                all_success = False
    else:
        log_msg.append("  No database dumps found.")

    log_msg.append("")
    log_msg.append("=" * 50)
    if all_success:
        log_msg.append("Restore complete!")
    else:
        log_msg.append("Restore completed with errors — check log!")
    log_msg.append("=" * 50)

    return {
        "success": all_success,
        "date": date_str,
        "log": "\n".join(log_msg)
    }

# --- HTTP Handler ------------------------------------------------------------
class BackupHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        try:
            if path == "/api/status":
                self.send_json(get_olares_status())
            elif path == "/api/backups":
                self.send_json(get_backup_status())
            elif path == "/api/apps":
                self.send_json(get_apps())
            elif path == "/api/export/dates":
                self.send_json({"config": get_export_dates(), "db": get_db_dates()})
            elif path.startswith("/api/export/details/"):
                date_str = path.split("/api/export/details/")[1]
                self.send_json(get_export_details(date_str))
            elif path == "/api/export/status":
                self.send_json(last_export)
            elif path == "/":
                html_path = "/app/backup-manager.html"
                if os.path.exists(html_path):
                    with open(html_path, "r") as f:
                        html = f.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.end_headers()
                    self.wfile.write(html.encode("utf-8"))
                else:
                    self.send_json({"error": "backup-manager.html not found"}, 404)
            else:
                self.send_json({"error": f"Unknown endpoint: {path}"}, 404)
        except Exception as e:
            self.send_json({"error": str(e)}, 500)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length) if content_length > 0 else b"{}"
            try:
                data = json.loads(body) if body else {}
            except json.JSONDecodeError:
                data = {}

            if path == "/api/export/config":
                self.send_json(trigger_export("config"))

            elif path == "/api/export/db":
                self.send_json(trigger_export("db"))

            elif path == "/api/restore":
                date_str = data.get("date", "")
                dry_run = data.get("dry_run", False)
                if not date_str:
                    self.send_json({"error": "Missing 'date' parameter"}, 400)
                else:
                    self.send_json(perform_restore(date_str, dry_run))

            else:
                self.send_json({"error": f"Unknown POST endpoint: {path}"}, 404)
        except Exception as e:
            self.send_json({"error": str(e)}, 500)

def main():
    parser = argparse.ArgumentParser(description="Rewind — Olares Backup Supplement")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("0.0.0.0", args.port), BackupHandler)
    print("=" * 60)
    print("  Rewind — Olares Backup Supplement")
    print("=" * 60)
    print(f"  Server: http://0.0.0.0:{args.port}")
    print(f"  Backup dir: {BACKUP_DIR}")
    print("=" * 60)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n\nServer stopped.")
        sys.exit(0)

if __name__ == "__main__":
    main()
