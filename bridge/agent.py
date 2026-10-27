#!/usr/bin/env python3
"""
agent.py — Local HTTP Webhook Agent for cloud-agent-bridge v2.0
Listens on 127.0.0.1 ONLY; exposed externally via cloudflared Tunnel.

Supported POST actions:
  - "exec"        : Run synchronous bash command (capped at 85s to avoid Cloudflare HTTP 524)
  - "exec_async"  : Launch long-running background task (>85s) and return job_id immediately
  - "job_status"  : Poll status, exit code, stdout, and stderr of an async job_id
  - "upload"      : Base64 file upload (replaces SFTP put, respects isolated AI_USER)
  - "download"    : Base64 file download (replaces SFTP get, respects isolated AI_USER)
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


class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # Silence default stderr HTTP logs

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, {"status": "alive", "service": "cloud-agent-bridge", "version": "2.0"})

    def do_POST(self):
        st = load_ai_state()
        token = st.get("AI_PASS", "")
        if not token:
            return self._send(503, {"error": "AI token not configured on server"})

        auth = self.headers.get("Authorization", "")
        if not hmac.compare_digest(auth, f"Bearer {token}"):
            return self._send(401, {"error": "Unauthorized: invalid Bearer token"})

        if st.get("AI_LOCKED") == "1":
            return self._send(403, {"error": "Forbidden: AI user is currently locked by owner"})

        length = int(self.headers.get("Content-Length", "0"))
        try:
            req = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self._send(400, {"error": "Invalid JSON body"})

        action = req.get("action", "exec")
        ai_user = st.get("AI_USER", "")
        cur_user, use_sudo = resolve_user_context(ai_user)

        # --- 0. Ping / Health Check ---
        if action == "ping":
            return self._send(200, {
                "status": "ok",
                "service": "cloud-agent-bridge",
                "version": "2.0",
                "ai_user": ai_user or cur_user,
                "sudo": st.get("AI_SUDO", "off"),
            })

        # --- 1. Execute Synchronous Bash Command ---
        elif action == "exec":
            cmd = req.get("cmd", "")
            if not cmd:
                return self._send(400, {"error": "Missing 'cmd' field"})

            # Cap timeout at 85s to beat Cloudflare's 100s HTTP 524 gateway timeout
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
                # Run command as ai_user, but write logs/rc to job_dir owned by agent
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
                raw = base64.b64decode(req["data_b64"])
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


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), WebhookHandler)
    print(f"[cloud-agent-bridge] listening on http://127.0.0.1:{PORT}", flush=True)
    server.serve_forever()
