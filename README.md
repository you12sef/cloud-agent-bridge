# Cloud-Agent-Bridge

**Persistent, zero-dependency HTTPS Webhook bridge that gives AI agents — including GET-only web browsers like Gemini, plus ChatGPT, Claude, and local LLM agents — secure operational access to any Linux server behind NAT — no SSH keys, no `paramiko`, and no dropped sessions.**

`cloud-agent-bridge` connects sandboxed AI assistants to your home server or private VPS over standard HTTPS requests. The local agent accepts **both `HTTP POST` (JSON)** and **pure `HTTP GET` (Base64URL-encoded query payloads)**, and lets you switch between **Cloudflare Tunnels (`cloudflared`)** and **Pinggy HTTPS Tunnels** (`--provider pinggy`) to bypass Cloudflare's Bot Fight Mode when browsing from Google/Gemini web agents. It pairs a localhost-only Python micro-agent with the tunnel, enforces OS-level user isolation (`ai-*`), and provides an **HMAC-SHA256 signed `ntfy.sh` fallback** for automatic URL recovery after server reboots or tunnel rotations.

## Key Features

| Feature | What It Gives You |
| :--- | :--- |
| **Transport Protocol** | **HTTPS Webhook** — `POST` (JSON body) **and** `GET` (Base64URL payloads in the query string) |
| **Gemini / Web-Browse Support** | **Native `HTTP GET` payload injection** + `--provider pinggy` (WAF-free browsing for Google/Gemini web agents) |
| **Tunnel Providers** | **Cloudflare Tunnel (`cf`, default)** with continuous connection, **or** **Pinggy HTTPS (`pinggy`)** — switchable with one command |
| **AI Sandbox Setup** | **Zero dependencies** (`curl`, Python `urllib`, or a simple browser GET URL) |
| **Authentication** | **256-bit Bearer Token** (`hmac.compare_digest` timing-safe via `Authorization` header or `?token=`) |
| **Long-Running Tasks** | **Built-in Async Jobs API** (`exec_async` & `job_status`) |
| **Reboot / Renewal Discovery** | **HMAC-SHA256 signed `RENEW` records** verified with the Bearer Token |
| **Instant Revocation** | **Zero-latency state reload** (`--ai-user lock` / `rotate`) |

## How It Works

```text
AI Assistant (Gemini / Claude / ChatGPT)      Your Linux Server (Behind NAT / Firewall)
┌──────────────────────────────────────┐      ┌──────────────────────────────────────────────────┐
│ • Mode A: HTTPS POST (JSON body)     │      │ HTTPS Tunnel (Cloudflare OR Pinggy HTTPS)        │
│ • Mode B: HTTPS GET (Gemini Browse)  │ ───► │   │                                              │
│   /?token=<TOK>&cmd_b64=<BASE64URL>  │      │   ▼                                              │
│   /?token=<TOK>&p=<BASE64URL_JSON>   │      │ Local Webhook Agent (127.0.0.1:18080)            │
│                                      │      │   • Validates Token & Lock state                 │
│                                      │      │   • Executes as isolated OS user (sudo -u ai-*)  │
└──────────────────────────────────────┘      │   • Kills hung process trees after 85s           │
                                              └──────────────────────────────────────────────────┘
               ▲                                                       │
               └─────── HMAC-SHA256 Signed URL (on reboot/renewal) ────┘
                                  via ntfy.sh Fallback Topic
```

## Quick Start

Copy the project folder to your Linux server and run:

```bash
chmod +x cloud-agent-bridge.sh

# Option A: Default (Cloudflare Quick Tunnel — continuous connection, best for curl/Python AI sandboxes)
bash cloud-agent-bridge.sh --start

# Option B: For Gemini Chat (Pinggy HTTPS — has NO Cloudflare WAF/Bot-Fight blocking Google's crawler)
bash cloud-agent-bridge.sh --start --provider pinggy
```

What `--start` does automatically:
1. **Prepares the tunnel binary**: With the default `cf` provider it detects your CPU architecture (`amd64`, `arm64`, `arm`) and downloads the official standalone Cloudflare `cloudflared` binary into `~/.cloud-agent-bridge/bin/` (no root required). With `pinggy` it uses the system's built-in `ssh` client — nothing to download.
2. **Creates an Isolated AI User (`ai-<hex>`)**: Creates a dedicated, unprivileged Linux account and generates a 40-character cryptographic API token stored in `~/.cloud-agent-bridge/ai-user.env` (`chmod 600`).
3. **Starts the Local Webhook Agent & Tunnel**: Launches `agent.py` on `127.0.0.1:18080` and exposes it via the selected tunnel provider.
4. **Installs Self-Healing Crontab Supervision**: Adds `@reboot` and `*/5 * * * *` cron entries to ensure the watchdog, agent, and tunnel automatically recover from crashes or reboots (and renews Pinggy URLs proactively every ~50 minutes).
5. **Prints the AI Handoff Block**: Outputs the paste-ready credentials block for your AI chat.

You can switch tunnel providers at any time with a single command:
```bash
cloud-agent-bridge --provider pinggy   # Switch to Pinggy HTTPS (best for Gemini web browsing)
cloud-agent-bridge --provider cf       # Switch to Cloudflare Quick Tunnel
```

## Connecting Your AI Assistant

Run `cloud-agent-bridge --handoff` (or copy the bottom block from `--start` / `--status`) and paste it into your AI chat alongside `AI-HANDOFF.md`:

```text
=== CLOUD-AGENT-BRIDGE AI HANDOFF ===
server name : ubuntu-prod
webhook url : https://random-words-here.trycloudflare.com
api token   : 8f9a2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a
tunnel mode : cf
ntfy topic  : cab-fleet-9b1154b018a3c4d5e6f7a8b9
ai user     : ai-7f3a1b2c (sudo: off, locked: 0)
============================================
```

Your AI assistant can immediately run commands without installing any packages:

```bash
# 1) Standard HTTPS POST (curl / Python sandboxes):
curl -s -X POST "https://random-words-here.trycloudflare.com" \
  -H "Authorization: Bearer 8f9a2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a" \
  -H "Content-Type: application/json" \
  -d '{"action":"exec","cmd":"hostname && whoami && uptime"}'
```

```text
# 2) Pure HTTPS GET (for Gemini / browse-only AI):
https://random-words-here.trycloudflare.com/?token=8f9a2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a&action=exec&cmd_b64=aG9zdG5hbWUgJiYgd2hvYW1pICYmIHVwdGltZQ
```

## Using with Gemini (Pure HTTP GET Payload Mode)

Because Gemini's sandbox blocks direct outbound shell traffic and Cloudflare's free `trycloudflare.com` domain blocks Google's automated web crawler ("Bot Fight Mode"), `cloud-agent-bridge` solves both constraints:

1. **Bypass Cloudflare WAF**: Run `cloud-agent-bridge --provider pinggy` on your server to expose `agent.py` over an HTTPS Pinggy link (`https://xxxx.a.free.pinggy.link`) which has no Cloudflare bot blocker.
2. **Execute Commands via Pure `HTTP GET` URLs**: `agent.py` accepts Base64URL-encoded commands or JSON payloads directly inside the URL query string:
   - **Quick Command (`cmd_b64`)**:
     ```text
     https://<WEBHOOK_URL>/?token=<API_TOKEN>&action=exec&cmd_b64=aG9zdG5hbWUgJiYgd2hvYW1pICYmIHVwdGltZQ
     ```
   - **Full JSON Payload (`p`)**:
     Encode any JSON request (e.g., `{"action":"exec","cmd":"ls -la"}`) using URL-safe Base64 and pass it in `?p=`:
     ```text
     https://<WEBHOOK_URL>/?token=<API_TOKEN>&p=eyJhY3Rpb24iOiJleGVjIiwiY21kIjoibHMgLWxhIn0
     ```
   - **Interactive Browser Console (`ui=1`)**:
     ```text
     https://<WEBHOOK_URL>/?token=<API_TOKEN>&ui=1
     ```

## Webhook API Reference (Works via POST or GET)

All requests authenticate with `Authorization: Bearer <API_TOKEN>` (POST) or `?token=<API_TOKEN>` (GET).

| Action | JSON Payload (for `POST` body or Base64URL `?p=`) | Direct `GET` Query Shorthand |
| :--- | :--- | :--- |
| **`exec`** | `{"action": "exec", "cmd": "ls -la", "cwd": "~", "timeout": 60}` | `?token=T&action=exec&cmd_b64=<B64URL>` |
| **`exec_async`** | `{"action": "exec_async", "cmd": "apt-get update && ..."}` | `?token=T&action=exec_async&cmd_b64=<B64URL>` |
| **`job_status`** | `{"action": "job_status", "job_id": "<id>"}` | `?token=T&action=job_status&job_id=<id>` |
| **`upload`** | `{"action": "upload", "path": "~/file.txt", "data_b64": "..."}` | `?token=T&p=<B64URL_JSON>` |
| **`download`** | `{"action": "download", "path": "~/file.txt"}` | `?token=T&action=download&path=~/file.txt` |
| **`ping`** | `{"action": "ping"}` | `?token=T&action=ping` |

Synchronous `exec` calls are capped at `85s` to avoid Cloudflare HTTP 524. POST returns the result JSON directly; GET returns the same JSON rendered as the response body.

## CLI Management Reference

After your first `--start`, `cloud-agent-bridge` is linked into `~/.local/bin` and `/usr/local/bin` so you can run it from any directory:

| Command | Description |
| :--- | :--- |
| `cloud-agent-bridge --start` | Install (first run) and start the watchdog, local agent, and tunnel |
| `cloud-agent-bridge --start --provider pinggy` | Start with the Pinggy HTTPS tunnel (WAF-free for Gemini browsing) |
| `cloud-agent-bridge --provider cf\|pinggy` | Switch tunnel provider between Cloudflare (`cf`) and Pinggy HTTPS (`pinggy`) |
| `cloud-agent-bridge --stop` | Stop the watchdog, tunnel, local webhook agent, and cron supervisor |
| `cloud-agent-bridge --status` | Show full service status, tunnel mode, AI user config, and handoff block |
| `cloud-agent-bridge --handoff` | Print **only** the paste-ready AI handoff block |
| `cloud-agent-bridge --restart` | Restart all bridge services |
| `cloud-agent-bridge --new-topic` | Generate a new 96-bit `ntfy.sh` fallback topic and restart |
| `cloud-agent-bridge --tunnel-token <TOK> [URL]` | Upgrade to a permanent Named Cloudflare Tunnel on your own domain |
| `cloud-agent-bridge --uninstall` | Stop services and remove cron, PATH links, and `~/.cloud-agent-bridge` state |
| `cloud-agent-bridge --purge` | Same as `--uninstall`, plus deletes the project folder |

### AI User & Security Controls (Instant Effect)

The local webhook agent reads `~/.cloud-agent-bridge/ai-user.env` on every incoming request. Security changes take effect **immediately** without restarting the tunnel:

```bash
cloud-agent-bridge --ai-user status   # View AI OS user, token, lock state, and sudo state
cloud-agent-bridge --ai-user rotate   # Generate a new 40-char Bearer token (active immediately)
cloud-agent-bridge --ai-user lock     # Block all AI requests immediately (returns HTTP 403)
cloud-agent-bridge --ai-user unlock   # Restore AI webhook access
cloud-agent-bridge --ai-user remove   # Delete the ai-* OS user, sudoers rules, and token
cloud-agent-bridge --ai-sudo on|off   # Grant or revoke passwordless sudo for the ai-* user
```

## Optional: Permanent URLs with a Named Cloudflare Tunnel

By default, the `cf` provider uses **Cloudflare Quick Tunnels** (`*.trycloudflare.com`), which require zero account setup. Quick Tunnels stay alive indefinitely while the server runs, and only change their URL if the server reboots (which the AI recovers from automatically via the HMAC-signed `ntfy.sh` topic).

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
| `cloud-agent-bridge.sh` | Unified CLI manager (`--start`, `--stop`, `--status`, `--handoff`, `--provider`, `--ai-user`, `--ai-sudo`) | Server |
| `bridge/agent.py` | Localhost HTTP GET/POST Webhook server (`127.0.0.1:18080`) handling `exec`, `exec_async`, `job_status`, `upload`, `download`, and the browser console UI | Server |
| `bridge/watchdog.sh` | Process supervisor for `agent.py` + tunnel (Cloudflare or Pinggy) with `flock` locking, proactive Pinggy renewal, and HMAC-SHA256 `ntfy.sh` publishing | Server |
| `bridge/discover.py` | Zero-dependency Python CLI for AI sandboxes: POST/GET executor, GET-URL builder (`--make-get-url`), and HMAC fallback URL verifier | AI Sandbox / Client |
| `AI-HANDOFF.md` | Ultra-concise operational manual designed to be given to AI models (covers both GET and POST modes) | AI Chat |
| `README.md` | Full project documentation | Documentation |

## Requirements

- **Server**: Any Linux distribution (Ubuntu, Debian, CentOS, Alpine, Raspberry Pi OS) with `bash`, `python3` (stdlib only), `curl` or `wget`, and `openssl`. Root/`sudo` is optional (used only to isolate commands inside a dedicated `ai-*` OS user; falls back cleanly to the current user if `sudo` is unavailable). The optional Pinggy provider uses the built-in `ssh` client — nothing extra to install.
- **AI Environment**: Outbound HTTPS (`curl`, Python 3 standard library, or a plain web-browsing tool for GET URLs).
