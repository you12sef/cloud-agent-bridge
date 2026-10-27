# Cloud-Agent-Bridge (v2.0)

**Persistent, zero-dependency HTTPS Webhook bridge that gives AI agents secure operational access to any Linux server behind NAT — no SSH keys, no `paramiko`, and no 60-minute tunnel drops.**

`cloud-agent-bridge` connects sandboxed AI assistants (ChatGPT, Claude, Gemini, local LLM agents) to your home server or private VPS over standard HTTPS POST requests. It pairs a localhost-only Python micro-agent with a **Cloudflare Tunnel (`cloudflared`)**, enforces OS-level user isolation (`ai-*`), and provides an **HMAC-SHA256 signed `ntfy.sh` fallback** for automatic URL recovery after server reboots.

## Why v2.0? (Architecture Upgrade)

| Feature | Legacy v1 (Pinggy + SSH) | Cloud-Agent-Bridge v2.0 (Cloudflare + Webhook) |
| :--- | :--- | :--- |
| **Transport Protocol** | Raw TCP SSH tunnel via Pinggy Free | **HTTPS Webhook via Cloudflare Tunnel (`cloudflared`)** |
| **Session Stability** | Hard-killed every 50–60 minutes | **Continuous connection** (no hourly drops) |
| **AI Sandbox Setup** | Required `pip install paramiko` & SSH handshake | **Zero dependencies** (`curl` or Python `urllib` out of the box) |
| **Authentication** | Plaintext SSH password + `AutoAddPolicy()` (MITM risk) | **256-bit Bearer Token** (`hmac.compare_digest` timing-safe) |
| **Long-Running Tasks** | Dropped on tunnel renewal | **Built-in Async Jobs API** (`exec_async` & `job_status`) |
| **Reboot Discovery** | Unsigned public `ntfy.sh` messages (spoofing risk) | **HMAC-SHA256 signed `RENEW` records** verified with Bearer Token |
| **Instant Revocation** | Required `usermod` + `sshd` reload | **Zero-latency state reload** (`--ai-user lock` / `rotate`) |

## How It Works

```text
AI Sandbox (Any LLM Chat)                     Your Linux Server (Behind NAT / Firewall)
┌──────────────────────────────┐              ┌──────────────────────────────────────────────────┐
│ Standard HTTPS POST          │              │ cloudflared (Auto-installed, no root required)   │
│  • curl / urllib.request     │ ===HTTPS===► │   │                                              │
│  • Header: Bearer <TOKEN>    │              │   ▼                                              │
│  • Actions:                  │              │ Local Webhook Agent (127.0.0.1:18080)            │
│    - exec / exec_async       │              │   • Validates Bearer Token & Lock state          │
│    - job_status              │              │   • Executes as isolated OS user (sudo -u ai-*)  │
│    - upload / download       │              │   • Kills hung process trees after 85s           │
└──────────────────────────────┘              └──────────────────────────────────────────────────┘
               ▲                                                       │
               └─────── HMAC-SHA256 Signed URL (on reboot ONLY) ───────┘
                                  via ntfy.sh Fallback Topic
```

## Quick Start

Copy the project folder to your Linux server and run a single command:

```bash
chmod +x cloud-agent-bridge.sh
bash cloud-agent-bridge.sh --start
```

What `--start` does automatically:
1. **Downloads `cloudflared`**: Detects your CPU architecture (`amd64`, `arm64`, `arm`) and downloads the official standalone Cloudflare binary into `~/.cloud-agent-bridge/bin/cloudflared` (no root required).
2. **Creates an Isolated AI User (`ai-<hex>`)**: Creates a dedicated, unprivileged Linux account and generates a 40-character cryptographic API token stored in `~/.cloud-agent-bridge/ai-user.env` (`chmod 600`).
3. **Starts the Local Webhook Agent & Tunnel**: Launches `agent.py` on `127.0.0.1:18080` and exposes it via a Cloudflare Quick Tunnel (`https://<random>.trycloudflare.com`).
4. **Installs Self-Healing Crontab Supervision**: Adds `@reboot` and `*/5 * * * *` cron entries to ensure the watchdog, agent, and tunnel automatically recover from crashes or reboots.
5. **Prints the AI Handoff Block**: Outputs the paste-ready credentials block for your AI chat.

## Connecting Your AI Assistant

Run `cloud-agent-bridge --handoff` (or copy the bottom block from `--start` / `--status`) and paste it into your AI chat alongside `AI-HANDOFF.md`:

```text
=== CLOUD-AGENT-BRIDGE AI HANDOFF (v2.0) ===
server name : ubuntu-prod
webhook url : https://random-words-here.trycloudflare.com
api token   : 8f9a2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a
ntfy topic  : cab-fleet-9b1154b018a3c4d5e6f7a8b9
ai user     : ai-7f3a1b2c (sudo: off, locked: 0)
============================================
```

Your AI assistant can immediately run commands without installing any packages:

```bash
curl -s -X POST "https://random-words-here.trycloudflare.com" \
  -H "Authorization: Bearer 8f9a2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a" \
  -H "Content-Type: application/json" \
  -d '{"action":"exec","cmd":"hostname && whoami && uptime"}'
```

## Webhook API Reference

All requests are sent via `HTTP POST` with `Authorization: Bearer <API_TOKEN>` and `Content-Type: application/json`.

| Action | Request Payload | Description |
| :--- | :--- | :--- |
| **`exec`** | `{"action": "exec", "cmd": "ls -la", "cwd": "~", "timeout": 60}` | Runs a synchronous Bash command (max timeout capped at `85s` to avoid Cloudflare HTTP 524). Returns `{"rc": 0, "stdout": "...", "stderr": "..."}`. |
| **`exec_async`** | `{"action": "exec_async", "cmd": "apt-get update && ..."}` | Starts a long-running task (>85s) in a detached background session and immediately returns `{"status": "started", "job_id": "<id>", "pid": 1234}`. |
| **`job_status`** | `{"action": "job_status", "job_id": "<id>"}` | Polls an async job. Returns `{"job_id": "...", "running": false, "rc": 0, "stdout": "...", "stderr": "..."}`. |
| **`upload`** | `{"action": "upload", "path": "~/file.txt", "data_b64": "..."}` | Decodes Base64 payload and writes it to `path` under the isolated `ai-*` user's ownership. |
| **`download`** | `{"action": "download", "path": "~/file.txt"}` | Reads `path` as the `ai-*` user and returns `{"status": "ok", "path": "...", "data_b64": "..."}`. |
| **`ping`** | `{"action": "ping"}` | Health check returning the active `ai_user` and `sudo` status. |

## CLI Management Reference

After your first `--start`, `cloud-agent-bridge` is linked into `~/.local/bin` and `/usr/local/bin` so you can run it from any directory:

| Command | Description |
| :--- | :--- |
| `cloud-agent-bridge --start` | Install (first run) and start the watchdog, local agent, and Cloudflare tunnel |
| `cloud-agent-bridge --stop` | Stop the watchdog, Cloudflare tunnel, local webhook agent, and cron supervisor |
| `cloud-agent-bridge --status` | Show full service status, tunnel mode, AI user config, and handoff block |
| `cloud-agent-bridge --handoff` | Print **only** the paste-ready AI handoff block |
| `cloud-agent-bridge --restart` | Restart all bridge services |
| `cloud-agent-bridge --new-topic` | Generate a new 96-bit `ntfy.sh` fallback topic and restart |
| `cloud-agent-bridge --tunnel-token <TOK> [URL]` | Upgrade from ephemeral Quick Tunnels to a permanent Named Cloudflare Tunnel |
| `cloud-agent-bridge --uninstall` | Stop services and remove cron, PATH links, and `~/.cloud-agent-bridge` state |
| `cloud-agent-bridge --purge` | Same as `--uninstall`, plus deletes the project folder |

### AI User & Security Controls (Instant Effect)

The local webhook agent reads `~/.cloud-agent-bridge/ai-user.env` on every incoming request. Security changes take effect **immediately** without restarting the Cloudflare tunnel:

```bash
cloud-agent-bridge --ai-user status   # View AI OS user, token, lock state, and sudo state
cloud-agent-bridge --ai-user rotate   # Generate a new 40-char Bearer token (active immediately)
cloud-agent-bridge --ai-user lock     # Block all AI requests immediately (returns HTTP 403)
cloud-agent-bridge --ai-user unlock   # Restore AI webhook access
cloud-agent-bridge --ai-user remove   # Delete the ai-* OS user, sudoers rules, and token
cloud-agent-bridge --ai-sudo on|off   # Grant or revoke passwordless sudo for the ai-* user
```

## Optional: Permanent URLs with a Named Cloudflare Tunnel

By default, `cloud-agent-bridge` uses **Cloudflare Quick Tunnels** (`*.trycloudflare.com`), which require zero account setup. Quick Tunnels stay alive indefinitely while the server runs, and only change their URL if the server reboots (which the AI recovers from automatically via the HMAC-signed `ntfy.sh` topic).

If you own a domain on Cloudflare and want a **permanent static URL** (e.g., `https://bridge.yourdomain.com`) that never changes even across reboots:
1. In your Cloudflare Zero Trust dashboard, create a Tunnel pointing to `http://127.0.0.1:18080` and copy the tunnel token.
2. Run:
   ```bash
   cloud-agent-bridge --tunnel-token "<YOUR_CF_TUNNEL_TOKEN>" "https://bridge.yourdomain.com"
   cloud-agent-bridge --restart
   ```

## Repository Structure

| File | Role | Location |
| :--- | :--- | :--- |
| `cloud-agent-bridge.sh` | Unified CLI manager (`--start`, `--stop`, `--status`, `--handoff`, `--ai-user`, `--ai-sudo`) | Server |
| `bridge/agent.py` | Localhost HTTP Webhook server (`127.0.0.1:18080`) handling `exec`, `exec_async`, `job_status`, `upload`, `download` | Server |
| `bridge/watchdog.sh` | Process supervisor for `agent.py` + `cloudflared` with `flock` locking and HMAC-SHA256 `ntfy.sh` publishing | Server |
| `bridge/discover.py` | Zero-dependency Python CLI for AI sandboxes to verify HMAC fallback URLs and call the webhook API | AI Sandbox / Client |
| `AI-HANDOFF.md` | Ultra-concise operational manual designed to be given to AI models | AI Chat |
| `README.md` | Full project documentation | Documentation |

## Requirements

- **Server**: Any Linux distribution (Ubuntu, Debian, CentOS, Alpine, Raspberry Pi OS) with `bash`, `python3` (stdlib only), `curl` or `wget`, and `openssl`. Root/`sudo` is optional (used only to isolate commands inside a dedicated `ai-*` OS user; falls back cleanly to the current user if `sudo` is unavailable).
- **AI Environment**: Outbound HTTPS (`curl` or Python 3 standard library).
