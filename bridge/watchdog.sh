#!/usr/bin/env bash
# =============================================================
# watchdog.sh — Supervises local Webhook Agent + Tunnel (Cloudflare / Pinggy HTTPS / localhost.run)
# Part of the "cloud-agent-bridge" kit (see README.md)
# =============================================================
CAB_DIR="$HOME/.cloud-agent-bridge"
NTFY_TOPIC="__TOPIC__"
SERVER_NAME="__SERVER__"
AGENT_PORT="__PORT__"
LOG="$CAB_DIR/watchdog.log"
STATE="$CAB_DIR/current.json"
STATE_ENV="$CAB_DIR/state.env"
AI_STATE_FILE="$CAB_DIR/ai-user.env"

mkdir -p "$CAB_DIR"
log() { echo "[$(date '+%F %T')] $$ $*" >> "$LOG"; }

# ---- single-instance flock/mkdir arbitration ----
MYPID=$$ LOCK="$CAB_DIR/watchdog.lock"
CAB_LOCKED=""
if command -v flock >/dev/null 2>&1 && [ -w "$CAB_DIR" ]; then
    exec 9>>"$LOCK" 2>/dev/null
    if flock -n 9 2>/dev/null; then
        CAB_LOCKED="flock"
    else
        exec 9>&- 2>/dev/null || true
    fi
fi
if [ -z "$CAB_LOCKED" ]; then
    if ! mkdir "$LOCK.dir" 2>/dev/null; then
        _oldpid="$(head -1 "$LOCK.dir/pid" 2>/dev/null || true)"
        if [ -n "$_oldpid" ] && ! kill -0 "$_oldpid" 2>/dev/null; then
            rm -rf "$LOCK.dir"
            mkdir "$LOCK.dir" 2>/dev/null || true
        fi
    fi
    if mkdir "$LOCK.dir" 2>/dev/null; then
        CAB_LOCKED="mkdir"
    else
        log "another watchdog is running — exiting"
        exit 0
    fi
fi
printf '%s\n' "$MYPID" > "$LOCK" 2>/dev/null || true
[ "$CAB_LOCKED" = "mkdir" ] && printf '%s\n' "$MYPID" > "$LOCK.dir/pid" 2>/dev/null || true

CAB_EXIT_REASON="normal exit"
trap 'CAB_EXIT_REASON="SIGINT"; exit 0' INT
trap 'CAB_EXIT_REASON="SIGTERM"; exit 0' TERM
trap 'rm -rf "$CAB_DIR/watchdog.lock.dir" 2>/dev/null; log "watchdog exiting — reason: $CAB_EXIT_REASON"' EXIT

find_cf() {
    command -v cloudflared 2>/dev/null || printf '%s' "$CAB_DIR/bin/cloudflared"
}

trim_logs() {
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
        tail -n 1000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        log "watchdog.log trimmed (was > 2 MB)"
    fi
}

sign_msg() { # $1 = payload -> prints HMAC-SHA256 using AI_PASS
    local payload="$1" AI_PASS=""
    [ -f "$AI_STATE_FILE" ] && . "$AI_STATE_FILE"
    if [ -n "${AI_PASS:-}" ] && command -v openssl >/dev/null 2>&1; then
        printf '%s' "$payload" | openssl dgst -sha256 -hmac "$AI_PASS" | awk '{print $NF}'
    else
        printf 'unsigned'
    fi
}

publish_ntfy() { # $1 = event (RENEW), $2 = url
    local kind="$1" url="$2" ts sig msg
    ts="$(date +%s)"
    sig="$(sign_msg "${kind}|${SERVER_NAME}|${url}|${ts}")"
    msg="${kind} ${SERVER_NAME} ${url} ${ts} ${sig}"
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 15 -o /dev/null -H "Title: cloud-agent-bridge $SERVER_NAME" \
             -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" 2>/dev/null || true
    fi
}

ensure_agent() {
    if ! pgrep -f 'python3.*cloud-agent-bridge/agent\.py' >/dev/null 2>&1; then
        log "starting local agent.py on 127.0.0.1:$AGENT_PORT"
        CAB_AGENT_PORT="$AGENT_PORT" setsid nohup python3 "$CAB_DIR/agent.py" \
            >> "$CAB_DIR/agent.log" 2>&1 < /dev/null &
        sleep 1
    fi
}

ensure_ssh_key() {
    local keyf="$CAB_DIR/tunnel_id_ed25519"
    if [ ! -f "$keyf" ] && command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -t ed25519 -N "" -f "$keyf" >/dev/null 2>&1 \
            || ssh-keygen -t rsa -b 2048 -N "" -f "$keyf" >/dev/null 2>&1 || true
        chmod 600 "$keyf" 2>/dev/null || true
    fi
    printf '%s' "$keyf"
}

lhr_healthy() { # POST /ping through the public URL; HTTP 200 = forwarding alive
    local code AI_PASS=""
    [ -n "$CUR_URL" ] || return 1
    [ -f "$AI_STATE_FILE" ] && . "$AI_STATE_FILE"
    [ -n "${AI_PASS:-}" ] || return 0
    code="$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${AI_PASS}" -H 'Content-Type: application/json' \
        -d '{"action":"ping"}' "$CUR_URL" 2>/dev/null)"
    [ "$code" = "200" ]
}

tunnel_running() {
    local TUNNEL_PROVIDER="cf"
    [ -f "$STATE_ENV" ] && . "$STATE_ENV"
    case "${TUNNEL_PROVIDER:-cf}" in
        pinggy) pgrep -f 'ssh.*free\.pinggy\.io' >/dev/null 2>&1 ;;
        lhr)    pgrep -f 'ssh.*localhost\.run' >/dev/null 2>&1 ;;
        *)      pgrep -f 'cloudflared tunnel.*(127\.0\.0\.1|--token)' >/dev/null 2>&1 ;;
    esac
}

start_tunnel() {
    local cf urlf="$CAB_DIR/tunnel_new.log" url i keyf key_opt=()
    local TUNNEL_PROVIDER="cf" CF_TUNNEL_TOKEN="" CUSTOM_WEBHOOK_URL=""
    [ -f "$STATE_ENV" ] && . "$STATE_ENV"
    pkill -f 'cloudflared tunnel.*(127\.0\.0\.1|--token)' 2>/dev/null || true
    pkill -f 'ssh.*(free\.pinggy\.io|localhost\.run)' 2>/dev/null || true
    rm -f "$urlf"

    if [ "${TUNNEL_PROVIDER:-cf}" = "pinggy" ]; then
        keyf="$(ensure_ssh_key)"
        [ -f "$keyf" ] && key_opt=(-i "$keyf")
        # -T (no pseudo-terminal) makes Pinggy print plain-text URLs instead of ANSI TUI codes
        setsid nohup ssh -T -p 443 "${key_opt[@]}" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ServerAliveInterval=30 \
            -o ServerAliveCountMax=3 \
            -o ExitOnForwardFailure=yes \
            -R0:127.0.0.1:${AGENT_PORT} a@free.pinggy.io > "$urlf" 2>&1 < /dev/null &
        echo $! > "$CAB_DIR/tunnel.pid"
        for i in $(seq 1 25); do
            sleep 3
            url="$(grep -oE 'https://[a-zA-Z0-9.-]+\.(pinggy\.link|pinggy-free\.link)' "$urlf" 2>/dev/null | head -1)"
            if [ -n "$url" ]; then
                printf '%s' "$url"
                return 0
            fi
        done
        return 1
    fi

    if [ "${TUNNEL_PROVIDER:-cf}" = "lhr" ]; then
        keyf="$(ensure_ssh_key)"
        [ -f "$keyf" ] && key_opt=(-i "$keyf")
        setsid nohup ssh -T "${key_opt[@]}" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ServerAliveInterval=30 \
            -o ServerAliveCountMax=3 \
            -o ExitOnForwardFailure=yes \
            -R80:127.0.0.1:${AGENT_PORT} nokey@localhost.run > "$urlf" 2>&1 < /dev/null &
        echo $! > "$CAB_DIR/tunnel.pid"
        for i in $(seq 1 25); do
            sleep 3
            url="$(grep -oE 'https://[a-zA-Z0-9.-]+\.(lhr\.life|localhost\.run)' "$urlf" 2>/dev/null | grep -v 'admin\.localhost\.run' | head -1)"
            if [ -n "$url" ]; then
                printf '%s' "$url"
                return 0
            fi
        done
        return 1
    fi

    cf="$(find_cf)"
    if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
        setsid nohup "$cf" tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN" \
            > "$urlf" 2>&1 < /dev/null &
        echo $! > "$CAB_DIR/tunnel.pid"
        sleep 3
        printf '%s' "${CUSTOM_WEBHOOK_URL:-https://named-tunnel-configured.example.com}"
        return 0
    fi

    setsid nohup "$cf" tunnel --no-autoupdate --url "http://127.0.0.1:${AGENT_PORT}" \
        > "$urlf" 2>&1 < /dev/null &
    echo $! > "$CAB_DIR/tunnel.pid"

    for i in $(seq 1 25); do
        sleep 3
        url="$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$urlf" 2>/dev/null | head -1)"
        if [ -n "$url" ]; then
            printf '%s' "$url"
            return 0
        fi
    done
    return 1
}

CUR_URL=""
START_TS=$(date +%s)
HOUSE=0
log "===== watchdog started: server=$SERVER_NAME port=$AGENT_PORT ====="

while true; do
    HOUSE=$((HOUSE + 1))
    [ $((HOUSE % 60)) -eq 0 ] && trim_logs

    ensure_agent
    NOW=$(date +%s)
    AGE=$(( NOW - START_TS ))
    TUNNEL_PROVIDER="cf"
    [ -f "$STATE_ENV" ] && . "$STATE_ENV"

    # Renew if tunnel died OR if an SSH free tier is nearing its drop window
    # (pinggy ~50-60m, localhost.run ~30m observed) or failing its health probe
    NEED_START=0
    if ! tunnel_running || [ -z "$CUR_URL" ]; then
        NEED_START=1
    elif [ "${TUNNEL_PROVIDER:-cf}" = "pinggy" ] && [ "$AGE" -ge 3000 ]; then
        log "pinggy 50-min proactive renewal triggered"
        NEED_START=1
    elif [ "${TUNNEL_PROVIDER:-cf}" = "lhr" ] && [ "$AGE" -ge 1500 ]; then
        log "lhr 25-min proactive renewal triggered"
        NEED_START=1
    elif [ "${TUNNEL_PROVIDER:-cf}" = "lhr" ] && [ $((HOUSE % 6)) -eq 0 ] && ! lhr_healthy; then
        log "lhr health probe failed - restarting tunnel"
        NEED_START=1
    fi

    if [ "$NEED_START" -eq 1 ]; then
        log "starting HTTPS Tunnel (provider: ${TUNNEL_PROVIDER:-cf})..."
        if new_url="$(start_tunnel)"; then
            START_TS=$(date +%s)
            if [ "$new_url" != "$CUR_URL" ]; then
                CUR_URL="$new_url"
                printf '{"server":"%s","provider":"%s","url":"%s","updated_at":"%s"}\n' \
                    "$SERVER_NAME" "${TUNNEL_PROVIDER:-cf}" "$CUR_URL" "$(date '+%F %T')" > "$STATE"
                publish_ntfy "RENEW" "$CUR_URL"
                log "tunnel active: $CUR_URL"
            fi
        else
            log "failed to obtain tunnel URL (retrying in 30s)"
            sleep 10
        fi
    fi
    sleep 20
done
