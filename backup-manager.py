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
from datetime import datetime, timezone, timedelta

# --- Config ------------------------------------------------------------------
DEFAULT_PORT = 8765
OLARES_CLI = "olares-cli"
BACKUP_DIR = "/Data/Backup"
CONFIG_DIR = f"{BACKUP_DIR}/config"

# Täglicher automatischer Export (UTC, HH:MM). Überschreibbar via Env EXPORT_SCHEDULE.
EXPORT_SCHEDULE = os.environ.get("EXPORT_SCHEDULE", "03:00")

last_export = {
    "config": None,
    "status": "idle"
}
export_lock = threading.Lock()

schedule_state = {
    "scheduled": EXPORT_SCHEDULE,
    "next": None,
    "last_auto": None
}

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
    except FileNotFoundError:
        # olares-cli not found — return structured error instead of crashing
        return {"exit_code": -1, "stdout": "", "stderr": f"Command not found: {command.split()[0]}", "success": False}
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

def get_manifest(date_str):
    r = run_cmd(f"cat {CONFIG_DIR}/{date_str}/manifest.json 2>&1")
    if r["success"]:
        return parse_json(r["stdout"])
    return {"error": "Manifest not found"}

def get_export_details(date_str):
    config_manifest = get_manifest(date_str)

    r = run_cmd(f"find {CONFIG_DIR}/{date_str} -type f | head -50 2>&1")
    config_files = r["stdout"].strip().split("\n") if r["success"] else []

    r = run_cmd(f"du -sh {CONFIG_DIR}/{date_str} 2>&1")
    config_size = r["stdout"].strip().split()[0] if r["success"] else "unknown"

    return {
        "date": date_str,
        "config_manifest": config_manifest,
        "config_files": config_files[:50],
        "config_size": config_size
    }

def list_export_apps(date_str):
    r = run_cmd(f"ls -1d {CONFIG_DIR}/{date_str}/apps/*/ 2>/dev/null")
    if not r["success"] or not r["stdout"].strip():
        return []
    return [os.path.basename(d.rstrip("/")) for d in r["stdout"].strip().split("\n") if d.strip()]

def _run_export_background():
    timestamp = datetime.now().strftime("%Y-%m-%d")
    script = "olares-config-export.sh"
    cmd = f"bash /app/{script} 2>&1"

    # Lange Laufzeit (30+ olares-cli-Calls + Pro-App-Calls) — 15 Min Budget.
    r = run_cmd(cmd, timeout=900)

    with export_lock:
        if r["success"] or "completed" in r["stdout"]:
            last_export["config"] = {
                "timestamp": datetime.now().isoformat(),
                "date": timestamp,
                "status": "success",
                "output": (r["stdout"] or "")[-500:]
            }
            last_export["status"] = "success"
        else:
            last_export["config"] = {
                "timestamp": datetime.now().isoformat(),
                "date": timestamp,
                "status": "error",
                "output": (r["stderr"] or r["stdout"] or "Unknown error")[-500:]
            }
            last_export["status"] = "error"


def trigger_export():
    with export_lock:
        current = last_export.get("config")
        if current and current.get("status") == "running":
            return {"status": "running", "message": "Config-Export läuft bereits"}
        last_export["config"] = {
            "timestamp": None,
            "date": datetime.now().strftime("%Y-%m-%d"),
            "status": "running",
            "output": ""
        }
        last_export["status"] = "running"

    t = threading.Thread(target=_run_export_background, daemon=True)
    t.start()
    return {"status": "started", "message": "Config-Export läuft im Hintergrund (mehrere Minuten)"}


# --- Täglicher Auto-Export (In-App-Cron) ------------------------------------
def _next_run_time(hhmm):
    now = datetime.now(timezone.utc)
    try:
        h, m = hhmm.split(":")
        target = now.replace(hour=int(h), minute=int(m), second=0, microsecond=0)
    except (ValueError, AttributeError):
        target = now.replace(hour=3, minute=0, second=0, microsecond=0)
    if target <= now:
        target += timedelta(days=1)
    return target


def _scheduler_loop():
    while True:
        nxt = _next_run_time(EXPORT_SCHEDULE)
        with export_lock:
            schedule_state["next"] = nxt.isoformat()
        sleep_secs = (nxt - datetime.now(timezone.utc)).total_seconds()
        if sleep_secs > 0:
            time.sleep(sleep_secs)
        # Täglichen Export anstoßen (asynchron)
        try:
            res = trigger_export()
            if res.get("status") in ("started", "running"):
                with export_lock:
                    schedule_state["last_auto"] = datetime.now(timezone.utc).isoformat()
        except Exception as e:
            print(f"[scheduler] export trigger failed: {e}", flush=True)
        # Kurz pausieren, damit der nächste Zyklus nicht sofort doppelt triggert
        time.sleep(30)

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

def perform_restore(date_str, apps=None):
    log_msg = []
    all_success = True

    log_msg.append(f"Restore der App-Einstellungen aus Export {date_str}...")
    log_msg.append(f"Quelle: {CONFIG_DIR}/{date_str}")
    log_msg.append("")

    # 1. Verify export exists
    r = run_cmd(f"test -d {CONFIG_DIR}/{date_str} && echo EXISTS || echo MISSING")
    if not r["success"] or "MISSING" in r["stdout"]:
        return {"success": False, "error": f"Export {date_str} not found at {CONFIG_DIR}/", "log": log_msg}

    log_msg.append("Export-Verzeichnis verifiziert.")

    # 2. Available apps
    available = list_export_apps(date_str)
    if not available:
        log_msg.append("Keine App-Einstellungen in diesem Export gefunden.")
        return {"success": True, "date": date_str, "log": "\n".join(log_msg)}

    if apps is None:
        selected = available
    else:
        selected = [a for a in apps if a in available]

    if not selected:
        log_msg.append("Keine Apps fuer den Restore ausgewaehlt.")
        return {"success": True, "date": date_str, "log": "\n".join(log_msg)}

    log_msg.append(f"{len(selected)} App(s) ausgewaehlt: {', '.join(selected)}")
    log_msg.append("")

    # 3. Restore App Settings (Domain + Policy pro Entrance)
    for app in selected:
        log_msg.append(f"-> {app}")

        # env.json enthaelt nur Var-Definitionen (keine Werte) — nicht wiederherstellbar, nur informativ
        env_data = read_export_json(date_str, f"apps/{app}/env.json")
        if env_data:
            log_msg.append("  -- env.json: nur Definitionen, keine Werte (nicht wiederherstellbar)")

        # Entrance-Dateien finden: domain-<entrance>.json / policy-<entrance>.json
        r = run_cmd(f"ls {CONFIG_DIR}/{date_str}/apps/{app}/ 2>/dev/null")
        entries = r["stdout"].strip().split("\n") if r["success"] else []
        entrances = []
        for e in entries:
            e = e.strip()
            if e.startswith("domain-") and e.endswith(".json"):
                entrances.append(e[len("domain-"):-len(".json")])

        if not entrances:
            log_msg.append("  -- keine Entrance-Domains im Export")
        else:
            for entrance in entrances:
                domain_data = read_export_json(date_str, f"apps/{app}/domain-{entrance}.json")
                if domain_data and isinstance(domain_data, dict):
                    third_level = domain_data.get("third_level_domain", "")
                    if third_level:
                        cmd = f"{OLARES_CLI} settings apps domain set {app} {entrance} --third-level {third_level}"
                        r = run_cmd(cmd, timeout=15)
                        if r["success"]:
                            log_msg.append(f"  OK: {app}/{entrance} domain -> {third_level}")
                        else:
                            log_msg.append(f"  WARN: {app}/{entrance} domain failed: {r['stderr'][:80]}")
                            all_success = False
                    else:
                        log_msg.append(f"  -- {app}/{entrance}: kein third_level gesetzt")

                policy_data = read_export_json(date_str, f"apps/{app}/policy-{entrance}.json")
                if policy_data and isinstance(policy_data, dict):
                    default_policy = policy_data.get("default_policy", "")
                    if default_policy in ("system", "one_factor", "two_factor", "public"):
                        cmd = f"{OLARES_CLI} settings apps policy set {app} {entrance} --default-policy {default_policy}"
                        r = run_cmd(cmd, timeout=15)
                        if r["success"]:
                            log_msg.append(f"  OK: {app}/{entrance} policy -> {default_policy}")
                        else:
                            log_msg.append(f"  WARN: {app}/{entrance} policy failed: {r['stderr'][:80]}")
                            all_success = False
                    elif default_policy:
                        log_msg.append(f"  -- {app}/{entrance}: policy-Wert '{default_policy}' nicht gueltig, uebersprungen")
                    else:
                        log_msg.append(f"  -- {app}/{entrance}: kein default_policy")

        log_msg.append("")

    log_msg.append("=" * 50)
    if all_success:
        log_msg.append("Restore abgeschlossen!")
    else:
        log_msg.append("Restore mit Warnungen abgeschlossen — Log pruefen!")
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
                self.send_json({"config": get_export_dates()})
            elif path.startswith("/api/export/details/"):
                date_str = path.split("/api/export/details/")[1]
                self.send_json(get_export_details(date_str))
            elif path == "/api/restore/apps":
                date_str = params.get("date", [""])[0]
                self.send_json({"apps": list_export_apps(date_str)} if date_str else {"error": "Missing 'date'"}, 400 if not date_str else 200)
            elif path == "/api/export/status":
                self.send_json(last_export)
            elif path == "/api/export/schedule":
                self.send_json(schedule_state)
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
            elif path == "/logo.png":
                logo_path = "/app/logo.png"
                if os.path.exists(logo_path):
                    with open(logo_path, "rb") as f:
                        logo = f.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "image/png")
                    self.send_header("Content-Length", str(len(logo)))
                    self.send_header("Cache-Control", "no-cache")
                    self.end_headers()
                    self.wfile.write(logo)
                else:
                    self.send_json({"error": "logo.png not found"}, 404)
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
                self.send_json(trigger_export())

            elif path == "/api/restore":
                date_str = data.get("date", "")
                apps = data.get("apps")
                if not date_str:
                    self.send_json({"error": "Missing 'date' parameter"}, 400)
                else:
                    if not isinstance(apps, list) or len(apps) == 0:
                        self.send_json({"error": "Bitte mindestens eine App für den Restore auswählen"}, 400)
                    else:
                        self.send_json(perform_restore(date_str, apps))

            else:
                self.send_json({"error": f"Unknown POST endpoint: {path}"}, 404)
        except Exception as e:
            self.send_json({"error": str(e)}, 500)

def main():
    parser = argparse.ArgumentParser(description="Rewind — Olares Backup Supplement")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("0.0.0.0", args.port), BackupHandler)

    # Täglicher Auto-Export starten
    scheduler = threading.Thread(target=_scheduler_loop, daemon=True)
    scheduler.start()
    print(f"  Auto-Export: täglich um {EXPORT_SCHEDULE} UTC")

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
