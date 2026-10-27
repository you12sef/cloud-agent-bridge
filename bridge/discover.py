#!/usr/bin/env python3
"""
discover.py — AI Client, GET/POST Executor & Fallback Discovery Tool for cloud-agent-bridge
Zero external dependencies (uses Python standard library only).

Features:
  1. Verify & discover HMAC-SHA256 signed Tunnel URLs from ntfy.sh fallback topic
  2. Execute commands via HTTP POST or HTTP GET (`--method get` for GET-only environments)
  3. Generate ready-to-browse GET URLs (`--make-get-url`) for AI models like Gemini
  4. Upload (`--upload`) and download (`--download`) files via Base64
"""
import argparse
import base64
import hashlib
import hmac
import json
import sys
import urllib.parse
import urllib.request


def b64url_encode(data_bytes):
    return base64.urlsafe_b64encode(data_bytes).decode("ascii").rstrip("=")


def discover_verified_url(topic, token):
    url = f"https://ntfy.sh/{topic}/json?poll=1&since=all"
    best_url, best_ts, best_server = "", 0, ""
    req = urllib.request.Request(url, headers={"User-Agent": "cloud-agent-bridge"})
    with urllib.request.urlopen(req, timeout=25) as r:
        for line in r.read().decode("utf-8", errors="replace").splitlines():
            try:
                m = json.loads(line)
            except Exception:
                continue
            p = m.get("message", "").split()
            # Expected format: RENEW <server> <url> <ts> <hmac_sig>
            if len(p) == 5 and p[0] == "RENEW" and p[2].startswith("https://"):
                payload = f"{p[0]}|{p[1]}|{p[2]}|{p[3]}".encode("utf-8")
                expected = hmac.new(token.encode("utf-8"), payload, hashlib.sha256).hexdigest()
                if hmac.compare_digest(expected, p[4]):
                    ts = int(p[3])
                    if ts >= best_ts:
                        best_ts, best_url, best_server = ts, p[2], p[1]
    return best_url, best_server, best_ts


def build_get_url(webhook_url, token, payload):
    p_b64 = b64url_encode(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    base = webhook_url.rstrip("/")
    return f"{base}/?token={urllib.parse.quote(token)}&p={p_b64}"


def call_webhook(webhook_url, token, payload, method="post", timeout=90):
    if method.lower() == "get":
        target = build_get_url(webhook_url, token, payload)
        req = urllib.request.Request(target, headers={"User-Agent": "cloud-agent-bridge"}, method="GET")
    else:
        req = urllib.request.Request(
            webhook_url,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "User-Agent": "cloud-agent-bridge",
            },
            method="POST",
        )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    ap = argparse.ArgumentParser(description="cloud-agent-bridge client & GET/POST discovery tool")
    ap.add_argument("--url", help="Webhook URL (https://...)")
    ap.add_argument("--topic", help="Fallback ntfy.sh topic (if --url is omitted or unreachable)")
    ap.add_argument("--token", required=True, help="40-char API Bearer token")
    ap.add_argument("--method", choices=["post", "get"], default="post", help="HTTP method to use (default: post)")
    ap.add_argument("--make-get-url", action="store_true", help="Print the encoded GET URL instead of calling it")
    ap.add_argument("--discover", action="store_true", help="Discover and verify latest HMAC-signed URL from ntfy")
    ap.add_argument("--cmd", help="Bash command to execute via webhook")
    ap.add_argument("--async-cmd", help="Launch a long-running background command (>85s)")
    ap.add_argument("--job-status", metavar="JOB_ID", help="Poll status of an async job")
    ap.add_argument("--upload", nargs=2, metavar=("LOCAL", "REMOTE"), help="Upload local file to remote path")
    ap.add_argument("--download", nargs=2, metavar=("REMOTE", "LOCAL"), help="Download remote file to local path")
    args = ap.parse_args()

    webhook_url = args.url
    if args.discover or not webhook_url:
        if not args.topic:
            ap.error("Either --url or --topic is required")
        best_url, srv, ts = discover_verified_url(args.topic, args.token)
        if not best_url:
            print("[!] No valid HMAC-signed RENEW URL found on topic.", file=sys.stderr)
            sys.exit(2)
        if args.discover:
            print(json.dumps({"server": srv, "url": best_url, "timestamp": ts}, indent=2))
            return
        webhook_url = best_url

    if args.cmd:
        payload = {"action": "exec", "cmd": args.cmd}
        if args.make_get_url:
            print(build_get_url(webhook_url, args.token, payload))
            return
        res = call_webhook(webhook_url, args.token, payload, method=args.method)
        sys.stdout.write(res.get("stdout", ""))
        if res.get("stderr"):
            sys.stderr.write(res["stderr"])
        sys.exit(res.get("rc", 0))

    if args.async_cmd:
        payload = {"action": "exec_async", "cmd": args.async_cmd}
        if args.make_get_url:
            print(build_get_url(webhook_url, args.token, payload))
            return
        res = call_webhook(webhook_url, args.token, payload, method=args.method)
        print(json.dumps(res, indent=2))
        return

    if args.job_status:
        payload = {"action": "job_status", "job_id": args.job_status}
        if args.make_get_url:
            print(build_get_url(webhook_url, args.token, payload))
            return
        res = call_webhook(webhook_url, args.token, payload, method=args.method)
        print(json.dumps(res, indent=2))
        return

    if args.upload:
        local_p, remote_p = args.upload
        with open(local_p, "rb") as f:
            b64 = base64.b64encode(f.read()).decode("ascii")
        res = call_webhook(webhook_url, args.token, {"action": "upload", "path": remote_p, "data_b64": b64}, method=args.method)
        print(json.dumps(res, indent=2))
        return

    if args.download:
        remote_p, local_p = args.download
        res = call_webhook(webhook_url, args.token, {"action": "download", "path": remote_p}, method=args.method)
        with open(local_p, "wb") as f:
            f.write(base64.b64decode(res["data_b64"]))
        print(json.dumps({"status": "ok", "saved_to": local_p}, indent=2))
        return


if __name__ == "__main__":
    main()
