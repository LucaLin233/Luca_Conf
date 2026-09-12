#!/usr/bin/env python3
"""Control Surge iOS through its localhost HTTP API."""
import argparse, json, os, sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

BASE = os.getenv("SURGE_HTTP_API_BASE", "http://127.0.0.1:6171").rstrip("/")
KEY = os.getenv("SURGE_HTTP_API_KEY")


def fail(message, code=2):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def validate_base():
    parsed = urlparse(BASE)
    if parsed.scheme not in ("http", "https"):
        fail("SURGE_HTTP_API_BASE must use http or https")
    if parsed.hostname not in ("127.0.0.1", "localhost", "::1") and os.getenv("SURGE_ALLOW_REMOTE") != "1":
        fail("Remote Surge API blocked; set SURGE_ALLOW_REMOTE=1 explicitly")
    if not KEY:
        fail("SURGE_HTTP_API_KEY is not set")


def request(method, path, body=None, dangerous=False, confirm=False):
    validate_base()
    if not path.startswith("/v1/"):
        fail("API path must start with /v1/")
    if "sensitive=1" in path and os.getenv("SURGE_ALLOW_SENSITIVE") != "1":
        fail("Sensitive profile export blocked; set SURGE_ALLOW_SENSITIVE=1 explicitly")
    if dangerous and not confirm:
        fail("This action requires --confirm-dangerous")
    data = None if body is None else json.dumps(body).encode()
    headers = {"X-Key": KEY, "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=30) as response:
            raw = response.read()
            ctype = response.headers.get("Content-Type", "")
    except HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        fail(f"HTTP {e.code}: {detail}", 1)
    except URLError as e:
        fail(f"Cannot reach Surge API at {BASE}: {e.reason}", 1)
    if "json" in ctype or raw[:1] in (b"{", b"["):
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass
    return raw.decode("utf-8", "replace")


def show(value):
    if isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(value)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--confirm-dangerous", action="store_true")
    sub = p.add_subparsers(dest="command", required=True)
    raw = sub.add_parser("request", help="Call an API endpoint")
    raw.add_argument("method", choices=("GET", "POST"))
    raw.add_argument("path")
    raw.add_argument("json_body", nargs="?")
    sub.add_parser("status")
    outbound = sub.add_parser("outbound")
    outbound.add_argument("mode", nargs="?", choices=("direct", "proxy", "rule"))
    feature = sub.add_parser("feature")
    feature.add_argument("name", choices=("mitm", "capture", "rewrite", "scripting"))
    feature.add_argument("state", nargs="?", choices=("on", "off"))
    sub.add_parser("policies")
    sub.add_parser("groups")
    select = sub.add_parser("select")
    select.add_argument("group")
    select.add_argument("policy", nargs="?")
    recent = sub.add_parser("requests")
    recent.add_argument("kind", choices=("recent", "active"), default="recent", nargs="?")
    kill = sub.add_parser("kill")
    kill.add_argument("id", type=int)
    sub.add_parser("profile")
    sub.add_parser("reload")
    sub.add_parser("dns")
    sub.add_parser("flush-dns")
    sub.add_parser("modules")
    module = sub.add_parser("module")
    module.add_argument("name")
    module.add_argument("state", choices=("on", "off"))
    for name in ("events", "rules", "traffic"):
        sub.add_parser(name)
    sub.add_parser("metrics", help="Read Prometheus metrics from /v1/metrics")
    sub.add_parser("stop")
    args = p.parse_args()

    c = args.command
    if c == "request":
        body = json.loads(args.json_body) if args.json_body else None
        show(request(args.method, args.path, body,
                     dangerous=args.path == "/v1/stop", confirm=args.confirm_dangerous))
    elif c == "status":
        result = {
            "outbound": request("GET", "/v1/outbound"),
            "features": {n: request("GET", f"/v1/features/{n}") for n in ("mitm", "capture", "rewrite", "scripting")},
        }
        show(result)
    elif c == "outbound":
        show(request("POST", "/v1/outbound", {"mode": args.mode}) if args.mode else request("GET", "/v1/outbound"))
    elif c == "feature":
        path = f"/v1/features/{args.name}"
        show(request("POST", path, {"enabled": args.state == "on"}) if args.state else request("GET", path))
    elif c == "policies": show(request("GET", "/v1/policies"))
    elif c == "groups": show(request("GET", "/v1/policy_groups"))
    elif c == "select":
        if args.policy:
            groups = request("GET", "/v1/policy_groups")
            if args.group not in groups:
                fail(f"Unknown policy group: {args.group}")
            available = {item.get("name") for item in groups[args.group] if item.get("enabled", True)}
            if args.policy not in available:
                fail(f"Policy is not an enabled option of {args.group}: {args.policy}")
            show(request("POST", "/v1/policy_groups/select", {"group_name": args.group, "policy": args.policy}))
        else:
            show(request("GET", "/v1/policy_groups/select?" + urlencode({"group_name": args.group})))
    elif c == "requests": show(request("GET", f"/v1/requests/{args.kind}"))
    elif c == "kill": show(request("POST", "/v1/requests/kill", {"id": args.id}))
    elif c == "profile": show(request("GET", "/v1/profiles/current?sensitive=0"))
    elif c == "reload": show(request("POST", "/v1/profiles/reload", {}))
    elif c == "dns": show(request("GET", "/v1/dns"))
    elif c == "flush-dns": show(request("POST", "/v1/dns/flush", {}))
    elif c == "modules": show(request("GET", "/v1/modules"))
    elif c == "module": show(request("POST", "/v1/modules", {args.name: args.state == "on"}))
    elif c in ("events", "rules", "traffic"): show(request("GET", f"/v1/{c}"))
    elif c == "metrics": show(request("GET", "/v1/metrics"))
    elif c == "stop": show(request("POST", "/v1/stop", {}, dangerous=True, confirm=args.confirm_dangerous))


if __name__ == "__main__":
    main()
