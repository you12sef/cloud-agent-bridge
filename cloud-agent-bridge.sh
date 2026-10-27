#!/usr/bin/env bash
# =====================================================================
#  cloud-agent-bridge.sh — Universal Tunnel + HTTP GET/POST Agent
#  Supports Cloudflare Quick Tunnels + Pinggy HTTPS + localhost.run HTTPS
#  Supports BOTH HTTP POST (JSON) and HTTP GET (Base64URL Payload + Web UI)
# ---------------------------------------------------------------------
#  Usage:
#    bash cloud-agent-bridge.sh --start                  install + start bridge
#    bash cloud-agent-bridge.sh --start --provider pinggy  use Pinggy HTTPS (WAF-free for Gemini)
#    bash cloud-agent-bridge.sh --start --provider lhr     use localhost.run HTTPS (WAF-free for Gemini)
#    bash cloud-agent-bridge.sh --stop                   full stop (watchdog + tunnel + agent)
#    bash cloud-agent-bridge.sh --status                 show status + AI handoff snippet
#    bash cloud-agent-bridge.sh --handoff                print ONLY the paste-ready AI snippet
#    bash cloud-agent-bridge.sh --restart                restart services
#    bash cloud-agent-bridge.sh --new-topic              rotate the fallback ntfy topic
#    bash cloud-agent-bridge.sh --provider cf|pinggy|lhr switch tunnel provider
#    bash cloud-agent-bridge.sh --tunnel-token T [URL]   configure a Named Cloudflare Tunnel token
#    bash cloud-agent-bridge.sh --uninstall              stop + remove cron/PATH/state
#    bash cloud-agent-bridge.sh --purge                  like --uninstall + delete project folder
#
#  Dedicated AI user & API Token management:
#    cloud-agent-bridge --ai-user create|status|rotate|lock|unlock|remove
#    cloud-agent-bridge --ai-sudo on|off
# =====================================================================
set -u
: "${HOME:?ERROR: HOME is not set}"
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

VERSION="2.2"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
WATCHDOG_TEMPLATE="$SCRIPT_DIR/bridge/watchdog.sh"
AGENT_SRC="$SCRIPT_DIR/bridge/agent.py"

REAL_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    REAL_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    REAL_HOME="${REAL_HOME:-$HOME}"
fi

CAB_DIR="$REAL_HOME/.cloud-agent-bridge"
STATE_FILE="$CAB_DIR/state.env"
AI_STATE_FILE="$CAB_DIR/ai-user.env"
BIN_DIR="$REAL_HOME/.local/bin"
BIN_LINK="$BIN_DIR/cloud-agent-bridge"
CF_BIN="$CAB_DIR/bin/cloudflared"
AGENT_PORT="${CAB_AGENT_PORT:-18080}"

SUDOERS_EXEC="/etc/sudoers.d/cloud-agent-bridge-exec"
SUDOERS_AI_SUDO="/etc/sudoers.d/cloud-agent-bridge-ai-sudo"

log()  { echo "[cloud-agent-bridge] $*"; }
warn() { echo "[cloud-agent-bridge] WARNING: $*" >&2; }
die()  { echo "[cloud-agent-bridge] ERROR: $*" >&2; exit 1; }

# ---------- action log ---------------------------------------------------
alog() {
    mkdir -p "$CAB_DIR" 2>/dev/null || true
    local who="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
    echo "[$(date '+%F %T')] $who $*" >> "$CAB_DIR/bridge.log" 2>/dev/null || true
    if [ -f "$CAB_DIR/bridge.log" ] \
       && [ "$(wc -c < "$CAB_DIR/bridge.log" 2>/dev/null || echo 0)" -gt 524288 ] 2>/dev/null; then
        tail -n 500 "$CAB_DIR/bridge.log" > "$CAB_DIR/.bridge.log.tmp" 2>/dev/null \
            && mv "$CAB_DIR/.bridge.log.tmp" "$CAB_DIR/bridge.log"
    fi
    return 0
}

# ---------- generators (high entropy) ------------------------------------
gen_hex() { # $1 = byte count (default 16 -> 32 hex chars)
    local bytes="${1:-16}" s=""
    if command -v openssl >/dev/null 2>&1; then
        s="$(openssl rand -hex "$bytes" 2>/dev/null)"
    fi
    [ -n "$s" ] || s="$(od -An -N"$bytes" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ -n "$s" ] || s="$(printf '%s%x%x' "$(date +%s)" "$RANDOM" "$RANDOM")"
    printf '%s' "$s"
}

gen_topic() { printf 'cab-fleet-%s' "$(gen_hex 12)"; }
gen_token() { gen_hex 20; } # 40-char hex token

# ---------- persisted state ----------------------------------------------
save_state() {
    mkdir -p "$CAB_DIR"
    { printf 'NTFY_TOPIC=%q\n' "$TOPIC"
      printf 'SERVER_NAME=%q\n' "$NAME"
      printf 'AGENT_PORT=%q\n' "$AGENT_PORT"
      printf 'TUNNEL_PROVIDER=%q\n' "${TUNNEL_PROVIDER:-cf}"
      printf 'CF_TUNNEL_TOKEN=%q\n' "${CF_TUNNEL_TOKEN:-}"
      printf 'CUSTOM_WEBHOOK_URL=%q\n' "${CUSTOM_WEBHOOK_URL:-}"
      printf 'INSTALLED_AT=%q\n' "$INSTALLED_AT"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown "$SUDO_USER" "$STATE_FILE" 2>/dev/null || true
    fi
}

load_state() {
    NTFY_TOPIC=""; SERVER_NAME=""; INSTALLED_AT=""; TUNNEL_PROVIDER="cf"; CF_TUNNEL_TOKEN=""; CUSTOM_WEBHOOK_URL=""
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
    TOPIC="$NTFY_TOPIC"
    NAME="$SERVER_NAME"
    TUNNEL_PROVIDER="${TUNNEL_PROVIDER:-cf}"
    return 0
}

# ---------- cloudflared auto-installer (no root needed) ------------------
ensure_cloudflared() {
    [ "${TUNNEL_PROVIDER:-cf}" != "cf" ] && return 0
    if command -v cloudflared >/dev/null 2>&1; then
        CF_BIN="$(command -v cloudflared)"
        return 0
    fi
    if [ -x "$CF_BIN" ]; then
        return 0
    fi
    mkdir -p "$CAB_DIR/bin"
    local arch url
    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        aarch64|arm64)  arch="arm64" ;;
        armv7l|armv6l)  arch="arm" ;;
        *) die "unsupported CPU architecture for cloudflared: $(uname -m)" ;;
    esac
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    log "downloading cloudflared ($arch) to $CF_BIN ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$CF_BIN.tmp" || die "failed to download cloudflared via curl"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$CF_BIN.tmp" "$url" || die "failed to download cloudflared via wget"
    else
        die "neither curl nor wget found — cannot download cloudflared"
    fi
    chmod +x "$CF_BIN.tmp"
    mv "$CF_BIN.tmp" "$CF_BIN"
    log "cloudflared installed successfully"
}

# ---------- SSH key for passwordless tunnel providers --------------------
ensure_tunnel_ssh_key() {
    [ "${TUNNEL_PROVIDER:-cf}" = "cf" ] && return 0
    mkdir -p "$CAB_DIR"
    local keyf="$CAB_DIR/tunnel_id_ed25519"
    if [ ! -f "$keyf" ]; then
        if command -v ssh-keygen >/dev/null 2>&1; then
            ssh-keygen -t ed25519 -N "" -f "$keyf" >/dev/null 2>&1 \
                || ssh-keygen -t rsa -b 2048 -N "" -f "$keyf" >/dev/null 2>&1 || true
            chmod 600 "$keyf" 2>/dev/null || true
        fi
    fi
}

# ---------- PATH integration ---------------------------------------------
path_install() {
    mkdir -p "$BIN_DIR" 2>/dev/null || true
    ln -sfn "$SELF" "$BIN_LINK" 2>/dev/null || { warn "could not create $BIN_LINK"; return 0; }
    if [ -f "$REAL_HOME/.bashrc" ] && ! grep -qs '^# >>> cloud-agent-bridge >>>$' "$REAL_HOME/.bashrc"; then
        { echo ""
          echo "# >>> cloud-agent-bridge >>>"
          echo 'export PATH="$HOME/.local/bin:$PATH"'
          echo "# <<< cloud-agent-bridge <<<"
        } >> "$REAL_HOME/.bashrc"
        log "added cloud-agent-bridge to PATH — run: source ~/.bashrc"
    fi
    [ -f "$REAL_HOME/.bashrc" ] || {
        { echo "# >>> cloud-agent-bridge >>>"
          echo 'export PATH="$HOME/.local/bin:$PATH"'
          echo "# <<< cloud-agent-bridge <<<"
        } > "$REAL_HOME/.bashrc"
    }
    if [ "$(id -u)" -eq 0 ]; then
        ln -sfn "$SELF" /usr/local/bin/cloud-agent-bridge 2>/dev/null || true
    elif sudo -n true 2>/dev/null; then
        sudo -n ln -sfn "$SELF" /usr/local/bin/cloud-agent-bridge 2>/dev/null || true
    fi
    return 0
}

path_remove() {
    rm -f "$BIN_LINK"
    sudo -n rm -f /usr/local/bin/cloud-agent-bridge 2>/dev/null || true
    if [ -f "$REAL_HOME/.bashrc" ]; then
        sed -i '/^# >>> cloud-agent-bridge >>>$/,/^# <<< cloud-agent-bridge <<<$/d' "$REAL_HOME/.bashrc" 2>/dev/null || true
    fi
    return 0
}

# ---------- crontab supervision ------------------------------------------
cron_add() {
    command -v crontab >/dev/null 2>&1 || { warn "crontab not available — autostart disabled"; return 0; }
    if ( crontab -l 2>/dev/null | grep -v 'cloud-agent-bridge/watchdog.sh'
         echo "@reboot $CAB_DIR/watchdog.sh >> $CAB_DIR/watchdog.log 2>&1"
         echo "*/5 * * * * pgrep -f 'bash[[:space:]]+[^[:space:]]*cloud-agent-bridge/watchdog\\.sh' >/dev/null 2>&1 || { sleep 10; pgrep -f 'bash[[:space:]]+[^[:space:]]*cloud-agent-bridge/watchdog\\.sh' >/dev/null 2>&1 || ( setsid nohup $CAB_DIR/watchdog.sh >> $CAB_DIR/watchdog.log 2>&1 < /dev/null & ) ; }"
       ) | crontab - 2>/dev/null; then
        log "autostart @reboot + */5 supervision enabled"
    else
        warn "crontab installation failed"
    fi
}

cron_remove() {
    command -v crontab >/dev/null 2>&1 || return 0
    crontab -l 2>/dev/null | grep -q 'cloud-agent-bridge/watchdog.sh' || return 0
    ( crontab -l 2>/dev/null | grep -v 'cloud-agent-bridge/watchdog.sh' ) | crontab - 2>/dev/null && log "crontab entries removed"
}

# ---------- process management -------------------------------------------
stop_services() {
    if pkill -f 'bash[[:space:]]+[^[:space:]]*cloud-agent-bridge/watchdog\.sh' 2>/dev/null; then
        log "watchdog: stopped"
    fi
    if pkill -f 'cloudflared tunnel.*(127\.0\.0\.1|--token)' 2>/dev/null; then
        log "cloudflared tunnel: stopped"
    fi
    if pkill -f 'ssh.*(free\.pinggy\.io|localhost\.run)' 2>/dev/null; then
        log "SSH HTTPS tunnel: stopped"
    fi
    if pkill -f 'python3.*cloud-agent-bridge/agent\.py' 2>/dev/null; then
        log "webhook agent: stopped"
    fi
    rm -rf "$CAB_DIR/watchdog.lock" "$CAB_DIR/watchdog.lock.dir" 2>/dev/null || true
    sleep 1
}

render_files() {
    [ -f "$WATCHDOG_TEMPLATE" ] || die "missing template: $WATCHDOG_TEMPLATE"
    [ -f "$AGENT_SRC" ] || die "missing agent script: $AGENT_SRC"
    mkdir -p "$CAB_DIR"
    cp -f "$AGENT_SRC" "$CAB_DIR/agent.py"
    chmod +x "$CAB_DIR/agent.py"

    sed -e "s|__TOPIC__|$TOPIC|g" \
        -e "s|__SERVER__|$NAME|g" \
        -e "s|__PORT__|$AGENT_PORT|g" \
        "$WATCHDOG_TEMPLATE" > "$CAB_DIR/watchdog.sh.tmp"
    mv "$CAB_DIR/watchdog.sh.tmp" "$CAB_DIR/watchdog.sh"
    chmod +x "$CAB_DIR/watchdog.sh"
}

launch_watchdog() {
    setsid nohup "$CAB_DIR/watchdog.sh" >> "$CAB_DIR/watchdog.log" 2>&1 < /dev/null &
    log "watchdog started (PID $!)"
}

grab_url() {
    load_state
    if [ -n "${CUSTOM_WEBHOOK_URL:-}" ]; then
        printf '%s' "$CUSTOM_WEBHOOK_URL"
        return 0
    fi
    local f url=""
    for f in "$CAB_DIR/current.json" "$CAB_DIR/tunnel_new.log"; do
        [ -f "$f" ] || continue
        url="$(grep -oE 'https://[a-zA-Z0-9.-]+\.(trycloudflare\.com|pinggy\.link|pinggy-free\.link|lhr\.life|localhost\.run)' "$f" 2>/dev/null | grep -v 'admin\.localhost\.run' | head -1)"
        [ -n "$url" ] && { printf '%s' "$url"; return 0; }
    done
    return 1
}

wait_url() {
    local i url=""
    for i in $(seq 1 "${1:-28}"); do
        sleep 3
        url="$(grab_url)" && break
    done
    [ -n "$url" ] && { printf '%s' "$url"; return 0; }
    return 1
}

# ---------- Dedicated AI User & API Token --------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    command -v sudo >/dev/null 2>&1 || die "root required and sudo is not available"
    log "this action needs root — re-running via sudo..."
    exec sudo bash "$SELF" "$@"
}

ai_state_load() {
    AI_USER=""; AI_SUDO="off"; AI_CREATED_AT=""; AI_PASS=""; AI_LOCKED="0"
    [ -f "$AI_STATE_FILE" ] && . "$AI_STATE_FILE"
    return 0
}

ai_state_save() {
    mkdir -p "$CAB_DIR" 2>/dev/null || true
    { printf 'AI_USER=%q\n' "$AI_USER"
      printf 'AI_SUDO=%q\n' "$AI_SUDO"
      printf 'AI_CREATED_AT=%q\n' "$AI_CREATED_AT"
      printf 'AI_PASS=%q\n' "$AI_PASS"
      printf 'AI_LOCKED=%q\n' "${AI_LOCKED:-0}"
    } > "$AI_STATE_FILE"
    chmod 600 "$AI_STATE_FILE" 2>/dev/null || true
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown "$SUDO_USER" "$AI_STATE_FILE" 2>/dev/null || true
    fi
}

ai_user_exists() { [ -n "${1:-}" ] && getent passwd "$1" >/dev/null 2>&1; }

ai_require_user() {
    ai_state_load
    [ -n "$AI_USER" ] || die "no AI user configured — run: cloud-agent-bridge --ai-user create"
}

ai_cmd_create() {
    require_root --ai-user create
    ai_state_load
    if [ -n "$AI_USER" ] && ai_user_exists "$AI_USER"; then
        die "AI user '$AI_USER' already exists — check: cloud-agent-bridge --ai-user status"
    fi
    local suf token owner
    suf="$(gen_hex 4)"
    AI_USER="ai-$suf"
    token="$(gen_token)"
    owner="${SUDO_USER:-$(id -un)}"

    useradd -m -s /bin/bash "$AI_USER" || die "useradd failed for $AI_USER"
    local ai_home
    ai_home="$(getent passwd "$AI_USER" 2>/dev/null | cut -d: -f6)"
    chmod 750 "${ai_home:-/home/$AI_USER}" 2>/dev/null || true

    # Allow the bridge owner to execute commands and file transfers as AI_USER without password prompt
    if [ -d /etc/sudoers.d ]; then
        printf '%s ALL=(%s) NOPASSWD: ALL\n' "$owner" "$AI_USER" > "$SUDOERS_EXEC"
        chmod 440 "$SUDOERS_EXEC"
    fi

    AI_SUDO="off"
    AI_CREATED_AT="$(date '+%F %T')"
    AI_PASS="$token"
    AI_LOCKED="0"
    ai_state_save
    alog "ai-user create user=$AI_USER"

    echo ""
    echo "=========================================================="
    echo "  DEDICATED AI USER & WEBHOOK TOKEN CREATED"
    echo "----------------------------------------------------------"
    echo "  OS User   : $AI_USER (isolated execution account)"
    echo "  API Token : $AI_PASS"
    echo "  Sudo      : OFF (enable with: cloud-agent-bridge --ai-sudo on)"
    echo "=========================================================="
}

ai_auto_setup() {
    ai_state_load
    if [ -n "$AI_PASS" ]; then
        log "existing AI configuration found (user: ${AI_USER:-local})"
        return 0
    fi
    log "setting up dedicated AI user and API token..."
    if [ "$(id -u)" -eq 0 ]; then
        ai_cmd_create
        return $?
    elif sudo -n true 2>/dev/null; then
        sudo -n bash "$SELF" --ai-user create && return 0
    else
        log "creating isolated OS user 'ai-*' requires sudo (press Ctrl+C to fallback to current user):"
        if sudo bash "$SELF" --ai-user create; then
            return 0
        fi
    fi
    # Fallback if user has no root/sudo: generate token and run under current OS user
    warn "sudo unavailable — generating API token for current user ($(id -un))"
    AI_USER="$(id -un)"
    AI_SUDO="off"
    AI_CREATED_AT="$(date '+%F %T')"
    AI_PASS="$(gen_token)"
    AI_LOCKED="0"
    ai_state_save
    return 0
}

ai_cmd_status() {
    ai_state_load
    echo "=========================================================="
    echo "  CLOUD-AGENT-BRIDGE — AI USER & TOKEN STATUS (v$VERSION)"
    echo "----------------------------------------------------------"
    if [ -z "$AI_PASS" ]; then
        echo "  Not configured. Run: cloud-agent-bridge --ai-user create"
        echo "=========================================================="
        return 0
    fi
    echo "  OS User   : ${AI_USER:-(current user)}"
    echo "  Created   : ${AI_CREATED_AT:-unknown}"
    echo "  Locked    : ${AI_LOCKED:-0}"
    echo "  Sudo      : ${AI_SUDO:-off}"
    echo "  API Token : $AI_PASS"
    echo "----------------------------------------------------------"
    echo "  rotate token : cloud-agent-bridge --ai-user rotate"
    echo "  lock/unlock  : cloud-agent-bridge --ai-user lock | unlock"
    echo "  sudo on/off  : cloud-agent-bridge --ai-sudo on | off"
    echo "=========================================================="
}

ai_cmd_rotate() {
    ai_state_load
    [ -n "$AI_PASS" ] || die "not configured yet — run: cloud-agent-bridge --start"
    AI_PASS="$(gen_token)"
    ai_state_save
    alog "ai-user rotate user=$AI_USER"
    echo "=========================================================="
    echo "  API TOKEN ROTATED (active immediately — no restart needed)"
    echo "  New Token : $AI_PASS"
    echo "=========================================================="
}

ai_cmd_lock() {
    ai_state_load
    [ -n "$AI_PASS" ] || die "not configured yet"
    AI_LOCKED="1"
    ai_state_save
    alog "ai-user lock user=$AI_USER"
    log "AI access LOCKED immediately (all webhook requests will return 403)."
}

ai_cmd_unlock() {
    ai_state_load
    [ -n "$AI_PASS" ] || die "not configured yet"
    AI_LOCKED="0"
    ai_state_save
    alog "ai-user unlock user=$AI_USER"
    log "AI access UNLOCKED."
}

ai_cmd_remove() {
    require_root --ai-user remove
    ai_state_load
    [ -n "$AI_USER" ] || die "no AI user configured"
    rm -f "$SUDOERS_EXEC" "$SUDOERS_AI_SUDO" 2>/dev/null || true
    if ai_user_exists "$AI_USER" && [[ "$AI_USER" == ai-* ]]; then
        userdel -r "$AI_USER" 2>/dev/null || warn "userdel failed for $AI_USER"
        log "OS user '$AI_USER' removed."
    fi
    rm -f "$AI_STATE_FILE"
    alog "ai-user remove user=$AI_USER"
    log "AI state and token removed."
}

ai_cmd_sudo() {
    local want="${1:-}"
    case "$want" in on|off) ;; *) die "usage: cloud-agent-bridge --ai-sudo on|off" ;; esac
    require_root --ai-sudo "$want"
    ai_require_user
    if [ "$want" = "on" ]; then
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$AI_USER" > "$SUDOERS_AI_SUDO"
        chmod 440 "$SUDOERS_AI_SUDO"
        AI_SUDO="on"
        ai_state_save
        alog "ai-sudo on user=$AI_USER"
        log "Full passwordless sudo ENABLED for '$AI_USER'."
    else
        rm -f "$SUDOERS_AI_SUDO" 2>/dev/null || true
        AI_SUDO="off"
        ai_state_save
        alog "ai-sudo off user=$AI_USER"
        log "sudo DISABLED for '$AI_USER'."
    fi
}

# ---------- main commands ------------------------------------------------
cmd_start() {
    load_state
    if [ -n "$FORCED_PROVIDER" ]; then
        TUNNEL_PROVIDER="$FORCED_PROVIDER"
    fi
    if [ -z "${TOPIC:-}" ]; then
        TOPIC="${FORCED_TOPIC:-$(gen_topic)}"
        NAME="${BRIDGE_NAME:-$(hostname)}"
        INSTALLED_AT="$(date '+%F %T')"
        save_state
        log "fresh install — fallback topic: $TOPIC (provider: $TUNNEL_PROVIDER)"
    else
        save_state
        log "reusing saved state — topic: $TOPIC (provider: $TUNNEL_PROVIDER)"
    fi
    [ -n "${NAME:-}" ] || NAME="$(hostname)"

    ensure_cloudflared
    ensure_tunnel_ssh_key
    ai_auto_setup
    render_files
    path_install
    stop_services
    rm -f "$CAB_DIR/tunnel_new.log" "$CAB_DIR/current.json"
    launch_watchdog
    cron_add

    if [ "$NO_WAIT" = 1 ]; then
        log "skipping URL wait (--no-wait) — check: cloud-agent-bridge --status"
        return 0
    fi

    if [ -n "${CUSTOM_WEBHOOK_URL:-}" ]; then
        print_handoff_snippet
        return 0
    fi

    log "waiting for HTTPS Tunnel URL (provider: $TUNNEL_PROVIDER, up to 80s)..."
    local url
    if url="$(wait_url 28)"; then
        print_handoff_snippet
    else
        warn "tunnel URL not ready yet — check in a moment with: cloud-agent-bridge --status"
        warn "or inspect tunnel log: cat $CAB_DIR/tunnel_new.log"
    fi
}

cmd_stop() {
    stop_services
    cron_remove
    alog "stop"
    log "bridge fully stopped."
}

cmd_status() {
    load_state
    ai_state_load
    local pid="" run_s="stopped" url="" cron_s="disabled" mode_s="Cloudflare Quick Tunnel (ephemeral)"
    pid="$(pgrep -f 'bash[[:space:]]+[^[:space:]]*cloud-agent-bridge/watchdog\.sh' 2>/dev/null | head -1)"
    [ -n "$pid" ] && run_s="running (PID $pid)"
    url="$(grab_url)" || url="(waiting for tunnel...)"
    crontab -l 2>/dev/null | grep -q 'cloud-agent-bridge/watchdog.sh' && cron_s="enabled (@reboot + */5)"
    [ "${TUNNEL_PROVIDER:-cf}" = "pinggy" ] && mode_s="Pinggy HTTPS Tunnel (WAF-free for Gemini GET/Browse)"
    [ "${TUNNEL_PROVIDER:-cf}" = "lhr" ] && mode_s="localhost.run HTTPS Tunnel (WAF-free for Gemini GET/Browse)"
    [ -n "${CF_TUNNEL_TOKEN:-}" ] && mode_s="Cloudflare Named Tunnel (persistent domain)"

    echo "=========================================================="
    echo "  CLOUD-AGENT-BRIDGE — STATUS (Universal HTTP GET/POST)"
    echo "----------------------------------------------------------"
    echo "  Service        : $run_s"
    echo "  Tunnel Mode    : $mode_s"
    echo "  Webhook URL    : $url"
    echo "  Local Agent    : http://127.0.0.1:${AGENT_PORT}"
    echo "  Fallback Topic : ${TOPIC:-(not installed)}"
    echo "  Server Name    : ${NAME:-$(hostname)}"
    echo "  Supervision    : $cron_s"
    echo "----------------------------------------------------------"
    echo "  AI OS User     : ${AI_USER:-(not set)}"
    echo "  API Token      : ${AI_PASS:-(not set)}"
    echo "  AI Locked      : ${AI_LOCKED:-0}"
    echo "  AI Sudo        : ${AI_SUDO:-off}"
    echo "=========================================================="
    print_handoff_snippet
}

print_handoff_snippet() {
    load_state
    ai_state_load
    local url
    url="$(grab_url)" || url="https://<pending-run-cloud-agent-bridge-status>"
    local tok="${AI_PASS:-(run: cloud-agent-bridge --start)}"

    local snip=""
    snip+="=== CLOUD-AGENT-BRIDGE AI HANDOFF ==="$'\n'
    snip+="server name : ${NAME:-$(hostname)}"$'\n'
    snip+="tunnel mode : ${TUNNEL_PROVIDER:-cf}"$'\n'
    snip+="webhook url : $url"$'\n'
    snip+="api token   : $tok"$'\n'
    snip+="ntfy topic  : ${TOPIC:-(none)}"$'\n'
    snip+="ai user     : ${AI_USER:-default} (sudo: ${AI_SUDO:-off}, locked: ${AI_LOCKED:-0})"$'\n'
    snip+="============================================"$'\n'
    snip+="1) Standard HTTPS POST (curl / Python):"$'\n'
    snip+="   curl -s -X POST \"$url\" -H \"Authorization: Bearer $tok\" -H \"Content-Type: application/json\" -d '{\"action\":\"exec\",\"cmd\":\"hostname && whoami && uptime\"}'"$'\n'
    snip+="2) Pure HTTPS GET (for Gemini / Browse-only AI):"$'\n'
    snip+="   Open or fetch: ${url}/?token=${tok}&action=exec&cmd_b64=aG9zdG5hbWUgJiYgd2hvYW1pICYmIHVwdGltZQ"$'\n'
    snip+="   (Encode any JSON payload as URL-safe Base64 in ?token=${tok}&p=<BASE64URL_JSON>)"

    echo ""
    echo "###### AI HANDOFF SNIPPET — paste this in chat for your AI ######"
    printf '%s\n' "$snip"
    echo "#################################################################"
}

cmd_new_topic() {
    load_state
    [ -n "${TOPIC:-}" ] || die "run --start first"
    TOPIC="$(gen_topic)"
    INSTALLED_AT="$(date '+%F %T')"
    save_state
    alog "new-topic topic=$TOPIC"
    render_files
    stop_services
    launch_watchdog
    log "new fallback topic: $TOPIC"
}

cmd_provider() {
    load_state
    local p="${1:-}"
    case "$p" in
        cf|cloudflare)        TUNNEL_PROVIDER="cf" ;;
        pinggy)               TUNNEL_PROVIDER="pinggy" ;;
        lhr|localhost.run)    TUNNEL_PROVIDER="lhr" ;;
        *) die "usage: cloud-agent-bridge --provider cf|pinggy|lhr" ;;
    esac
    save_state
    alog "provider=$TUNNEL_PROVIDER"
    log "switched tunnel provider to '$TUNNEL_PROVIDER' — restarting..."
    cmd_start
}

cmd_tunnel_token() {
    load_state
    CF_TUNNEL_TOKEN="${1:-}"
    CUSTOM_WEBHOOK_URL="${2:-}"
    if [ -z "$CF_TUNNEL_TOKEN" ]; then
        CF_TUNNEL_TOKEN=""
        CUSTOM_WEBHOOK_URL=""
        save_state
        log "cleared Named Tunnel token — reverting to default tunnel on next restart"
    else
        TUNNEL_PROVIDER="cf"
        save_state
        log "saved Cloudflare Named Tunnel token (custom URL: ${CUSTOM_WEBHOOK_URL:-none})"
        log "run 'cloud-agent-bridge --restart' to activate"
    fi
}

cmd_uninstall() {
    load_state
    if [ "$YES" != 1 ]; then
        printf "[cloud-agent-bridge] stop services and remove state/cron/PATH? (y/N): "
        read -r ans
        case "$ans" in y|Y|yes|YES) ;; *) log "cancelled."; exit 0 ;; esac
    fi
    stop_services
    cron_remove
    path_remove
    rm -rf "$CAB_DIR"
    log "uninstalled state dir: $CAB_DIR"
    if [ "$PURGE" = 1 ]; then
        cd "$REAL_HOME" || exit 1
        rm -rf "$SCRIPT_DIR"
        log "project folder deleted: $SCRIPT_DIR"
    fi
}

cmd_help() {
    cat <<'EOF'
cloud-agent-bridge — Universal HTTPS Tunnel + GET/POST Webhook Agent

Usage:
  bash cloud-agent-bridge.sh --start                      install & start tunnel + webhook agent
  bash cloud-agent-bridge.sh --start --provider pinggy    start with Pinggy HTTPS (WAF-free for Gemini)
  bash cloud-agent-bridge.sh --start --provider lhr       start with localhost.run HTTPS (WAF-free for Gemini)
  bash cloud-agent-bridge.sh --stop                       stop all bridge processes
  bash cloud-agent-bridge.sh --status                     show full status + handoff block
  bash cloud-agent-bridge.sh --handoff                    print ONLY the AI handoff snippet
  bash cloud-agent-bridge.sh --restart                    restart tunnel & agent
  bash cloud-agent-bridge.sh --provider cf|pinggy|lhr     switch between Cloudflare, Pinggy, and localhost.run
  bash cloud-agent-bridge.sh --new-topic                  rotate fallback ntfy topic
  bash cloud-agent-bridge.sh --tunnel-token <TOK> [URL]   use a permanent Named Cloudflare Tunnel
  bash cloud-agent-bridge.sh --uninstall                  remove cron, PATH, and ~/.cloud-agent-bridge
  bash cloud-agent-bridge.sh --purge                      uninstall + delete project directory

AI User & Token Control:
  cloud-agent-bridge --ai-user create|status|rotate|lock|unlock|remove
  cloud-agent-bridge --ai-sudo on|off
EOF
}

# ---------- CLI router ---------------------------------------------------
ACTION=""; PURGE=0; YES=0; NO_WAIT=0; BRIDGE_NAME=""; FORCED_TOPIC=""; FORCED_PROVIDER=""
TUNNEL_TOK_ARG=""; TUNNEL_URL_ARG=""; PROVIDER_ARG=""
AI_SUB=""; AI_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --start|start|--install|install) ACTION="start" ;;
        --stop|stop)                     ACTION="stop" ;;
        --status|status)                 ACTION="status" ;;
        --handoff|handoff)               ACTION="handoff" ;;
        --restart|restart)               ACTION="restart" ;;
        --new-topic|new-topic)           ACTION="new-topic" ;;
        --provider)
            if [ -z "$ACTION" ]; then
                ACTION="provider"
                PROVIDER_ARG="${2:-}"
            else
                FORCED_PROVIDER="${2:-}"
            fi
            shift ;;
        --tunnel-token)
            ACTION="tunnel-token"
            TUNNEL_TOK_ARG="${2:-}"
            TUNNEL_URL_ARG="${3:-}"
            break ;;
        --uninstall|uninstall)           ACTION="uninstall" ;;
        --purge)                         ACTION="uninstall"; PURGE=1 ;;
        --yes|-y)                        YES=1 ;;
        --no-wait)                       NO_WAIT=1 ;;
        --name)                          BRIDGE_NAME="${2:-}"; shift ;;
        --topic)                         FORCED_TOPIC="${2:-}"; shift ;;
        --ai-user)
            ACTION="ai-user"; AI_SUB="${2:-}"; shift 2; AI_ARGS=("$@"); break ;;
        --ai-sudo)
            ACTION="ai-sudo"; AI_SUB="${2:-}"; shift 2; AI_ARGS=("$@"); break ;;
        --version|-V)                    echo "cloud-agent-bridge v$VERSION"; exit 0 ;;
        -h|--help|help)                  cmd_help; exit 0 ;;
        *)                               die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[ -n "$ACTION" ] || { cmd_help; exit 1; }

case "$ACTION" in
    start)        cmd_start ;;
    stop)         cmd_stop ;;
    status)       cmd_status ;;
    handoff)      print_handoff_snippet ;;
    restart)      cmd_start ;;
    new-topic)    cmd_new_topic ;;
    provider)     cmd_provider "$PROVIDER_ARG" ;;
    tunnel-token) cmd_tunnel_token "$TUNNEL_TOK_ARG" "$TUNNEL_URL_ARG" ;;
    uninstall)    cmd_uninstall ;;
    ai-user)
        case "$AI_SUB" in
            create) ai_cmd_create ;;
            status) ai_cmd_status ;;
            rotate) ai_cmd_rotate ;;
            lock)   ai_cmd_lock ;;
            unlock) ai_cmd_unlock ;;
            remove) ai_cmd_remove ;;
            *) die "unknown --ai-user subcommand: $AI_SUB" ;;
        esac ;;
    ai-sudo)      ai_cmd_sudo "$AI_SUB" ;;
esac
