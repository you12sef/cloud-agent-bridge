# AI HANDOFF — Cloud-Agent-Bridge

> **SYSTEM DIRECTIVE FOR THE AI MODEL:**
> You have direct operational access to a remote Linux server via an **HTTPS Webhook** behind a Cloudflare Tunnel.
> - **DO NOT** use SSH or install `paramiko`.
> - **DO NOT** poll `ntfy.sh` during normal operation; connect directly to the `webhook url` below.
> - All command execution and file transfers happen over standard HTTPS `POST` requests authenticated with a Bearer Token.

## 1. Connection Parameters (Provided by User in Chat)

The user will paste the output of `cloud-agent-bridge --handoff` in the chat:

- **`webhook url`**: `https://<random-words>.trycloudflare.com` (or a custom domain)
- **`api token`**: `<40-char hex secret>`
- **`ntfy topic`**: `cab-fleet-<24-char hex>` *(Fallback ONLY if the webhook URL returns HTTP 530 / unreachable after a server reboot)*
- **`ai user`**: `ai-<hex>` *(Isolated Linux OS account; `sudo` is `off` unless explicitly enabled)*

## 2. Fast-Path Verification (Run This First)

Execute this single `curl` command (replacing `<WEBHOOK_URL>` and `<API_TOKEN>`) to verify connectivity, then reply:
`READY — connected to <hostname> as <user>, awaiting instructions.`

```bash
curl -s -X POST "<WEBHOOK_URL>" \
  -H "Authorization: Bearer <API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"action": "exec", "cmd": "hostname && whoami && uptime", "timeout": 30}'
```

**Expected JSON Response:**
```json
{"rc": 0, "stdout": "my-server\nai-7f3a1b2c\n 10:15:00 up 5 days...\n", "stderr": ""}
```

## 3. Core Operations (Python Zero-Dependency Helper)

Use this standard-library Python snippet for reliable command execution, background jobs, and file transfers:

```python
import base64, json, urllib.request

URL   = "<WEBHOOK_URL>"
TOKEN = "<API_TOKEN>"

def bridge(payload, timeout=90):
    req = urllib.request.Request(
        URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "cloud-agent-bridge"
        },
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))

# 1) Synchronous Command (<= 85s):
res = bridge({"action": "exec", "cmd": "ls -la", "cwd": "~", "timeout": 60})
print(res["rc"], res["stdout"], res["stderr"])

# 2) Long-Running Background Task (> 85s — avoids Cloudflare HTTP 524 timeout):
job = bridge({"action": "exec_async", "cmd": "sudo apt-get update && sudo apt-get upgrade -y"})
job_id = job["job_id"]

# Poll background job until running == False:
status = bridge({"action": "job_status", "job_id": job_id})
print(status["running"], status["rc"], status["stdout"])

# 3) Upload Local File to Server (Replaces SFTP put):
with open("local_script.py", "rb") as f:
    b64 = base64.b64encode(f.read()).decode("ascii")
print(bridge({"action": "upload", "path": "~/local_script.py", "data_b64": b64}))

# 4) Download File from Server (Replaces SFTP get):
dl = bridge({"action": "download", "path": "~/remote_output.log"})
with open("remote_output.log", "wb") as f:
    f.write(base64.b64decode(dl["data_b64"]))
```

## 4. Operational Rules & Guardrails

1. **85-Second Sync Ceiling**: Synchronous `exec` calls are capped at **85 seconds** so they never trigger Cloudflare's 100-second `HTTP 524` gateway timeout. For builds, downloads, or package installations taking longer than 60 seconds, **always** use `{"action": "exec_async", "cmd": "..."}` and poll with `{"action": "job_status", "job_id": "..."}`.
2. **Non-Interactive Execution**: `stdin` is bound to `/dev/null`. Always pass non-interactive flags (`-y`, `--yes`, `DEBIAN_FRONTEND=noninteractive`, `-o BatchMode=yes`).
3. **HTTP Error Codes**:
   - `401 Unauthorized`: Token was rotated by the owner (`cloud-agent-bridge --ai-user rotate`). Ask the user for the updated token.
   - `403 Forbidden`: Owner locked AI access (`cloud-agent-bridge --ai-user lock`). Stop and ask the user.
   - `408 Request Timeout`: Command exceeded `timeout` and its process group was killed (`SIGKILL`). Switch to `exec_async`.
   - `530 / Connection Error`: Server rebooted and the ephemeral Quick Tunnel URL changed. Run **Section 5** below.
4. **Platform-Layer `broken session: 403` (GLM models on Z.ai only — models in other environments can ignore this rule):**
   If a tool call fails with an error shaped like `failed to execute tool: ... broken session: 403 Forbidden`, that error comes from the **Z.ai platform tool-gateway**, **not** from the bridge (the bridge's lock response is the JSON `{"error": "Forbidden: AI user is currently locked by owner"}`). It means the platform's tool session was interrupted — a transient, platform-side event that is unrelated to the bridge or the server, so do **not** treat it as a lock and do **not** retry the same call repeatedly. The correct recovery: ask the user to send **any short trigger message** (for example `continue`, `استمر`, `اكمل`, or even `.`) — a new user message re-establishes the session and the model resumes from the existing conversation history. Avoid asking for a full session restart unless trigger messages repeatedly fail: a restart reloads the runtime and forces the model to repeat the entire task from the beginning. This situation is specific to GLM models because they run inside the Z.ai environment itself; assistants connecting from other sandboxes (ChatGPT, Claude, Gemini, ...) never see this platform-layer error.

## 5. Automatic Fallback Discovery (ONLY If Webhook URL Is Unreachable)

If and only if the server reboots and the `*.trycloudflare.com` URL stops responding, fetch and cryptographically verify the new URL from the `ntfy.sh` fallback topic using your `API_TOKEN` as the HMAC-SHA256 key:

```python
import hashlib, hmac, json, urllib.request

TOPIC = "<NTFY_TOPIC>"
TOKEN = "<API_TOKEN>"

req = urllib.request.Request(
    f"https://ntfy.sh/{TOPIC}/json?poll=1&since=all",
    headers={"User-Agent": "cloud-agent-bridge"}
)
with urllib.request.urlopen(req, timeout=25) as r:
    best_url, best_ts = "", 0
    for line in r.read().decode("utf-8", errors="replace").splitlines():
        try:
            m = json.loads(line)
        except Exception:
            continue
        p = m.get("message", "").split()
        # Signed format: RENEW <server> <https_url> <unix_ts> <hmac_sha256>
        if len(p) == 5 and p[0] == "RENEW" and p[2].startswith("https://"):
            payload = f"{p[0]}|{p[1]}|{p[2]}|{p[3]}".encode("utf-8")
            expected = hmac.new(TOKEN.encode("utf-8"), payload, hashlib.sha256).hexdigest()
            if hmac.compare_digest(expected, p[4]) and int(p[3]) >= best_ts:
                best_ts, best_url = int(p[3]), p[2]

print("Verified new Webhook URL:", best_url)
```
