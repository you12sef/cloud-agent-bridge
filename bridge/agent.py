#!/usr/bin/env python3
"""
agent.py — Universal HTTP GET/POST Webhook Agent for cloud-agent-bridge
Listens on 127.0.0.1 ONLY; exposed externally via Cloudflare Tunnel or Pinggy HTTPS.

Supports THREE ways for AI models to interact:
  1. HTTP POST (JSON body + Authorization: Bearer <TOKEN> header)
  2. HTTP GET  (Query parameters: ?token=<TOKEN>&p=<BASE64URL_JSON> or ?token=<TOKEN>&action=exec&cmd_b64=<BASE64URL_CMD>)
               -> Specifically designed for AI models whose web tools only support GET requests (like Gemini browse).
  3. Browser Console UI (GET /?token=<TOKEN>&ui=1) -> Interactive HTML page for browser-based AI agents.

Supported actions (in both GET and POST):
  - "exec"        : Run synchronous bash command (capped at 85s)
  - "exec_async"  : Launch long-running background task (>85s) and return job_id immediately
  - "job_status"  : Poll status, exit code, stdout, and stderr of an async job_id
  - "upload"      : Base64 file upload (respects isolated AI_USER)
  - "download"    : Base64 file download (respects isolated AI_USER)
  - "ping"        : Authenticated health & environment check
"""
import base64
import hmac
import json
import os
import shlex
import signal
import subprocess
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CAB_DIR = os.path.expanduser("~/.cloud-agent-bridge")
AI_STATE_FILE = os.path.join(CAB_DIR, "ai-user.env")
JOBS_DIR = os.path.join(CAB_DIR, "jobs")
PORT = int(os.environ.get("CAB_AGENT_PORT", "18080"))


def load_ai_state():
    state = {"AI_USER": "", "AI_PASS": "", "AI_LOCKED": "0", "AI_SUDO": "off"}
    if not os.path.isfile(AI_STATE_FILE):
        return state
    try:
        with open(AI_STATE_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    state[k.strip()] = shlex.split(v)[0] if v.strip() else ""
    except Exception:
        pass
    return state


def resolve_user_context(ai_user):
    cur_user = os.environ.get("USER", "")
    use_sudo = bool(ai_user and ai_user != cur_user)
    return cur_user, use_sudo


def expand_target_path(raw_path, ai_user, use_sudo):
    if use_sudo and raw_path.startswith("~"):
        if raw_path == "~":
            return f"/home/{ai_user}"
        if raw_path.startswith("~/"):
            return f"/home/{ai_user}/{raw_path[2:]}"
    return os.path.expanduser(raw_path)


def b64url_decode(s):
    s = s.strip().replace("-", "+").replace("_", "/")
    pad = (-len(s)) % 4
    if pad:
        s += "=" * pad
    return base64.b64decode(s)


WEB_UI_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Cloud-Agent-Bridge Console</title>
<style>
  body { font-family: monospace; background: #111; color: #eee; padding: 20px; }
  textarea, input { width: 100%; background: #222; color: #0f0; border: 1px solid #444; padding: 8px; margin: 6px 0; }
  button { padding: 8px 16px; background: #0a84ff; color: #fff; border: none; cursor: pointer; }
  pre { background: #000; border: 1px solid #333; padding: 12px; white-space: pre-wrap; }
</style>
</head>
<body>
<h2>Cloud-Agent-Bridge Console</h2>
<form method="GET" action="/">
  <input type="hidden" name="token" value="__TOKEN__">
  <input type="hidden" name="action" value="exec">
  <label>Command:</label>
  <input type="text" name="cmd" placeholder="hostname && whoami && uptime" autofocus>
  <button type="submit">Run via GET</button>
</form>
</body>
</html>
"""


class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # Silence default stderr HTTP logs

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, code, html_str):
        body = html_str.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authenticate(self, query_params=None):
        st = load_ai_state()
        token = st.get("AI_PASS", "")
        if not token:
            self._send(503, {"error": "AI token not configured on server"})
            return None

        provided = ""
        auth_hdr = self.headers.get("Authorization", "")
        if auth_hdr.startswith("Bearer "):
            provided = auth_hdr[7:].strip()
        elif query_params and "token" in query_params:
            provided = query_params["token"][0].strip()

        if not provided or not hmac.compare_digest(provided, token):
            self._send(401, {"error": "Unauthorized: invalid or missing token"})
            return None

        if st.get("AI_LOCKED") == "1":
            self._send(403, {"error": "Forbidden: AI user is currently locked by owner"})
            return None

        return st

    def _dispatch_action(self, req, st):
        action = req.get("action", "exec")
        ai_user = st.get("AI_USER", "")
        cur_user, use_sudo = resolve_user_context(ai_user)

        # --- 0. Ping / Health Check ---
        if action == "ping":
            return self._send(200, {
                "status": "ok",
                "service": "cloud-agent-bridge",
                "version": "2.2",
                "ai_user": ai_user or cur_user,
                "sudo": st.get("AI_SUDO", "off"),
            })

        # --- 1. Execute Synchronous Bash Command ---
        elif action == "exec":
            cmd = req.get("cmd", "")
            if not cmd:
                return self._send(400, {"error": "Missing 'cmd' field"})

            timeout = min(max(int(req.get("timeout", 60)), 1), 85)
            cwd = req.get("cwd") or None
            if cwd:
                cwd = expand_target_path(cwd, ai_user, use_sudo)

            if use_sudo:
                exec_argv = ["sudo", "-n", "-u", ai_user, "-H", "/bin/bash", "-c", cmd]
            else:
                exec_argv = ["/bin/bash", "-c", cmd]

            try:
                p = subprocess.Popen(
                    exec_argv,
                    cwd=cwd,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    start_new_session=True,
                )
                out, err = p.communicate(timeout=timeout)
                return self._send(200, {
                    "rc": p.returncode,
                    "stdout": out.decode("utf-8", errors="replace"),
                    "stderr": err.decode("utf-8", errors="replace"),
                })
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(p.pid), signal.SIGKILL)
                except Exception:
                    p.kill()
                out, err = p.communicate()
                return self._send(408, {
                    "rc": -1,
                    "error": f"Command timed out after {timeout}s (use action='exec_async' for long tasks)",
                    "stdout": out.decode("utf-8", errors="replace"),
                    "stderr": err.decode("utf-8", errors="replace"),
                })
            except Exception as e:
                return self._send(500, {"rc": -1, "error": str(e)})

        # --- 2. Execute Asynchronous Background Job (>85s tasks) ---
        elif action == "exec_async":
            cmd = req.get("cmd", "")
            if not cmd:
                return self._send(400, {"error": "Missing 'cmd' field"})

            os.makedirs(JOBS_DIR, exist_ok=True)
            job_id = uuid.uuid4().hex[:12]
            job_dir = os.path.join(JOBS_DIR, job_id)
            os.makedirs(job_dir, exist_ok=True)

            out_file = os.path.join(job_dir, "stdout.log")
            err_file = os.path.join(job_dir, "stderr.log")
            rc_file = os.path.join(job_dir, "rc")
            meta_file = os.path.join(job_dir, "meta.json")

            wrapped_cmd = f"({cmd}); echo $? > {shlex.quote(rc_file)}"
            if use_sudo:
                inner = f"sudo -n -u {shlex.quote(ai_user)} -H /bin/bash -c {shlex.quote(cmd)}"
                wrapped_cmd = f"{inner}; echo $? > {shlex.quote(rc_file)}"

            try:
                with open(out_file, "wb") as fout, open(err_file, "wb") as ferr:
                    p = subprocess.Popen(
                        ["/bin/bash", "-c", wrapped_cmd],
                        stdin=subprocess.DEVNULL,
                        stdout=fout,
                        stderr=ferr,
                        start_new_session=True,
                    )
                with open(meta_file, "w", encoding="utf-8") as fm:
                    json.dump({
                        "job_id": job_id,
                        "pid": p.pid,
                        "cmd": cmd,
                        "started_at": int(time.time()),
                    }, fm)
                return self._send(200, {
                    "status": "started",
                    "job_id": job_id,
                    "pid": p.pid,
                })
            except Exception as e:
                return self._send(500, {"error": str(e)})

        # --- 3. Check Async Job Status ---
        elif action == "job_status":
            job_id = req.get("job_id", "")
            if not job_id or "/" in job_id or ".." in job_id:
                return self._send(400, {"error": "Invalid 'job_id'"})

            job_dir = os.path.join(JOBS_DIR, job_id)
            if not os.path.isdir(job_dir):
                return self._send(404, {"error": f"Job not found: {job_id}"})

            out_file = os.path.join(job_dir, "stdout.log")
            err_file = os.path.join(job_dir, "stderr.log")
            rc_file = os.path.join(job_dir, "rc")

            running = not os.path.isfile(rc_file)
            rc = None
            if not running:
                try:
                    with open(rc_file, "r", encoding="utf-8") as f:
                        rc = int(f.read().strip())
                except Exception:
                    rc = -1

            stdout_str = ""
            stderr_str = ""
            if os.path.isfile(out_file):
                with open(out_file, "rb") as f:
                    stdout_str = f.read().decode("utf-8", errors="replace")
            if os.path.isfile(err_file):
                with open(err_file, "rb") as f:
                    stderr_str = f.read().decode("utf-8", errors="replace")

            return self._send(200, {
                "job_id": job_id,
                "running": running,
                "rc": rc,
                "stdout": stdout_str,
                "stderr": stderr_str,
            })

        # --- 4. Upload File (Base64) ---
        elif action == "upload":
            try:
                raw_path = req["path"]
                raw = b64url_decode(req["data_b64"])
                path = expand_target_path(raw_path, ai_user, use_sudo)

                if use_sudo:
                    parent = os.path.dirname(os.path.abspath(path))
                    subprocess.run(
                        ["sudo", "-n", "-u", ai_user, "-H", "mkdir", "-p", parent],
                        check=True,
                        stdin=subprocess.DEVNULL,
                    )
                    p = subprocess.Popen(
                        ["sudo", "-n", "-u", ai_user, "-H", "tee", path],
                        stdin=subprocess.PIPE,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                    )
                    _, err = p.communicate(input=raw, timeout=30)
                    if p.returncode != 0:
                        raise RuntimeError(err.decode("utf-8", errors="replace").strip())
                else:
                    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
                    with open(path, "wb") as f:
                        f.write(raw)

                return self._send(200, {"status": "ok", "path": path, "bytes": len(raw)})
            except Exception as e:
                return self._send(500, {"error": str(e)})

        # --- 5. Download File (Base64) ---
        elif action == "download":
            try:
                raw_path = req["path"]
                path = expand_target_path(raw_path, ai_user, use_sudo)

                if use_sudo:
                    p = subprocess.Popen(
                        ["sudo", "-n", "-u", ai_user, "-H", "cat", path],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    out, err = p.communicate(timeout=30)
                    if p.returncode != 0:
                        raise RuntimeError(err.decode("utf-8", errors="replace").strip())
                    b64 = base64.b64encode(out).decode("ascii")
                else:
                    with open(path, "rb") as f:
                        b64 = base64.b64encode(f.read()).decode("ascii")

                return self._send(200, {"status": "ok", "path": path, "data_b64": b64})
            except Exception as e:
                return self._send(500, {"error": str(e)})

        return self._send(400, {"error": f"Unknown action: {action}"})

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)

        # Unauthenticated root health probe if no token/payload parameters are passed
        if not qs:
            return self._send(200, {
                "status": "alive",
                "service": "cloud-agent-bridge",
                "version": "2.2",
                "modes": ["POST (JSON)", "GET (?token=...&p=<base64url_json>)", "GET (?token=...&cmd_b64=<base64url_cmd>)"]
            })

        st = self._authenticate(qs)
        if not st:
            return

        if "ui" in qs:
            return self._send_html(200, WEB_UI_HTML.replace("__TOKEN__", st.get("AI_PASS", "")))

        req = {}
        if "p" in qs:
            try:
                req = json.loads(b64url_decode(qs["p"][0]).decode("utf-8"))
            except Exception as e:
                return self._send(400, {"error": f"Invalid base64url JSON payload in 'p': {e}"})
        else:
            req["action"] = qs.get("action", ["exec"])[0]
            if "cmd_b64" in qs:
                try:
                    req["cmd"] = b64url_decode(qs["cmd_b64"][0]).decode("utf-8")
                except Exception as e:
                    return self._send(400, {"error": f"Invalid base64url in 'cmd_b64': {e}"})
            elif "cmd" in qs:
                req["cmd"] = qs["cmd"][0]
            if "cwd" in qs:
                req["cwd"] = qs["cwd"][0]
            if "timeout" in qs:
                req["timeout"] = int(qs["timeout"][0])
            if "job_id" in qs:
                req["job_id"] = qs["job_id"][0]
            if "path" in qs:
                req["path"] = qs["path"][0]
            if "data_b64" in qs:
                req["data_b64"] = qs["data_b64"][0]

        return self._dispatch_action(req, st)

    def do_POST(self):
        st = self._authenticate()
        if not st:
            return

        length = int(self.headers.get("Content-Length", "0"))
        try:
            req = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self._send(400, {"error": "Invalid JSON body"})

        return self._dispatch_action(req, st)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), WebhookHandler)
    print(f"[cloud-agent-bridge] listening on http://127.0.0.1:{PORT} (GET & POST enabled)", flush=True)
    server.serve_forever()
