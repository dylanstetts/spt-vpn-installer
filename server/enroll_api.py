"""
SPT-over-WireGuard enrollment + manifest API.

Endpoints (all require Bearer token from invites.json, except /health):
    GET  /health     -> {"ok": true}
    POST /enroll     {pubkey, name} -> {address, server_pubkey, endpoint,
                                        allowed_ips, dns, server_vpn_ip,
                                        spt_url}
    GET  /manifest   -> raw contents of MANIFEST_PATH (uploaded by the
                        host-PC publisher). The Azure VM does NOT host
                        mod zips or SPT/Fika releases; the manifest
                        points clients at public URLs.

Design notes:
  * Tokens are single-use by default. Consumed tokens are kept (with
    the assigned address + pubkey) so a friend can re-run the installer
    on the same machine and get the same IP back.
  * IP allocation walks POOL_CIDR skipping `reserved_ips` from
    config.json plus the server's own address and any address already
    handed out via invites.json.
  * Peers are written into a managed block of WG_CONF, then
    `wg syncconf` is invoked. The block is delimited by BEGIN/END
    markers so anything you add by hand outside the block (e.g. your
    Sunshine peers) is preserved.
  * This service is exposed on the public internet. It MUST be served
    over HTTPS - install-server.sh provisions a self-signed cert and
    prints its SHA256 fingerprint, which is pinned by the client
    installer at build time.
"""
from __future__ import annotations

import ipaddress
import json
import os
import secrets
import subprocess
import threading
from pathlib import Path
from typing import Any

from flask import Flask, abort, jsonify, request, send_file

# --- Config ------------------------------------------------------------------

CONFIG_PATH = Path(os.environ.get("ENROLL_CONFIG", "/etc/spt-vpn/config.json"))
INVITES_PATH = Path(os.environ.get("ENROLL_INVITES", "/etc/spt-vpn/invites.json"))
MANIFEST_PATH = Path(os.environ.get("MANIFEST_PATH", "/etc/spt-vpn/manifest.json"))
WG_CONF = Path(os.environ.get("WG_CONF", "/etc/wireguard/wg0.conf"))
WG_INTERFACE = os.environ.get("WG_INTERFACE", "wg0")

PEER_BLOCK_BEGIN = "# >>> spt-vpn managed peers (do not edit by hand) >>>"
PEER_BLOCK_END = "# <<< spt-vpn managed peers <<<"

_lock = threading.Lock()
app = Flask(__name__)


# --- Helpers -----------------------------------------------------------------

def _load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _save_json(path: Path, data: dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def _config() -> dict[str, Any]:
    return _load_json(CONFIG_PATH)


def _invites() -> dict[str, Any]:
    if not INVITES_PATH.exists():
        return {"tokens": {}}
    return _load_json(INVITES_PATH)


def _save_invites(data: dict[str, Any]) -> None:
    _save_json(INVITES_PATH, data)


def _require_token() -> dict[str, Any]:
    """Validate Bearer token; return its invite record."""
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        abort(401, "missing bearer token")
    token = auth[len("Bearer "):].strip()
    invites = _invites()
    record = invites.get("tokens", {}).get(token)
    if record is None:
        abort(403, "invalid token")
    return {"token": token, "record": record, "all": invites}


def _allocate_ip(invites: dict[str, Any], cfg: dict[str, Any]) -> str:
    pool = ipaddress.ip_network(cfg["pool_cidr"])
    server_ip = ipaddress.ip_address(cfg["server_vpn_ip"])
    used: set[ipaddress.IPv4Address | ipaddress.IPv6Address] = {
        ipaddress.ip_address(r["address"])
        for r in invites["tokens"].values()
        if r.get("address")
    }
    used.add(server_ip)
    for r in cfg.get("reserved_ips", []) or []:
        used.add(ipaddress.ip_address(r))
    hosts = pool.hosts() if pool.prefixlen < 31 else pool
    for ip in hosts:
        if ip not in used:
            return str(ip)
    abort(507, "address pool exhausted")


def _rewrite_wg_conf(invites: dict[str, Any]) -> None:
    """Rebuild the managed peer block in wg0.conf and apply with wg syncconf."""
    text = WG_CONF.read_text(encoding="utf-8") if WG_CONF.exists() else ""

    block_lines = [PEER_BLOCK_BEGIN]
    for token, rec in invites["tokens"].items():
        if not rec.get("pubkey") or not rec.get("address"):
            continue
        block_lines.append(f"# peer name={rec.get('name', '?')} token={token[:8]}...")
        block_lines.append("[Peer]")
        block_lines.append(f"PublicKey = {rec['pubkey']}")
        block_lines.append(f"AllowedIPs = {rec['address']}/32")
        block_lines.append("")
    block_lines.append(PEER_BLOCK_END)
    block = "\n".join(block_lines)

    if PEER_BLOCK_BEGIN in text and PEER_BLOCK_END in text:
        head, _, rest = text.partition(PEER_BLOCK_BEGIN)
        _, _, tail = rest.partition(PEER_BLOCK_END)
        new_text = f"{head.rstrip()}\n\n{block}\n{tail.lstrip()}"
    else:
        new_text = f"{text.rstrip()}\n\n{block}\n"

    WG_CONF.write_text(new_text, encoding="utf-8")
    # `wg syncconf` requires a stripped config (no [Interface] non-WG keys).
    stripped = subprocess.check_output(
        ["wg-quick", "strip", WG_INTERFACE], text=True
    )
    proc = subprocess.run(
        ["wg", "syncconf", WG_INTERFACE, "/dev/stdin"],
        input=stripped, text=True, capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"wg syncconf failed: {proc.stderr}")


# --- Routes ------------------------------------------------------------------

@app.get("/health")
def health() -> Any:
    return jsonify(ok=True)


@app.post("/enroll")
def enroll() -> Any:
    auth = _require_token()
    body = request.get_json(force=True, silent=True) or {}
    pubkey = (body.get("pubkey") or "").strip()
    name = (body.get("name") or "client").strip()[:32]
    if len(pubkey) != 44 or not pubkey.endswith("="):
        abort(400, "invalid pubkey")

    cfg = _config()
    with _lock:
        invites = _invites()
        record = invites["tokens"][auth["token"]]
        # Re-enroll on same token: reuse the assigned address unless the
        # token is marked rebindable.
        if record.get("pubkey") and record["pubkey"] != pubkey:
            if not record.get("rebindable", False):
                abort(409, "token already used by a different key")
        if not record.get("address"):
            record["address"] = _allocate_ip(invites, cfg)
        record["pubkey"] = pubkey
        record["name"] = name
        _save_invites(invites)
        _rewrite_wg_conf(invites)

    spt_host = cfg.get("spt_host_vpn_ip") or cfg["server_vpn_ip"]
    return jsonify(
        address=record["address"],
        server_pubkey=cfg["server_pubkey"],
        endpoint=cfg["endpoint"],
        allowed_ips=cfg["client_allowed_ips"],
        dns=cfg.get("dns"),
        server_vpn_ip=cfg["server_vpn_ip"],
        spt_host_vpn_ip=spt_host,
        spt_url=f"https://{spt_host}:6969",
    )


@app.get("/manifest")
def manifest() -> Any:
    _require_token()
    if not MANIFEST_PATH.exists():
        abort(503, "manifest not yet published")
    return send_file(
        MANIFEST_PATH,
        mimetype="application/json",
        as_attachment=False,
        conditional=True,
    )


# --- CLI helpers (run via `python enroll_api.py <cmd>`) ----------------------

def _cli_new_token(name: str) -> None:
    token = secrets.token_urlsafe(24)
    invites = _invites()
    invites.setdefault("tokens", {})[token] = {
        "name": name,
        "address": None,
        "pubkey": None,
        "rebindable": False,
    }
    _save_invites(invites)
    print(token)


def _cli_revoke(token: str) -> None:
    with _lock:
        invites = _invites()
        if token in invites.get("tokens", {}):
            del invites["tokens"][token]
            _save_invites(invites)
            _rewrite_wg_conf(invites)
            print("revoked")
        else:
            print("no such token")


if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 3 and sys.argv[1] == "new-token":
        _cli_new_token(sys.argv[2])
    elif len(sys.argv) >= 3 and sys.argv[1] == "revoke":
        _cli_revoke(sys.argv[2])
    elif len(sys.argv) >= 2 and sys.argv[1] == "list":
        print(json.dumps(_invites(), indent=2))
    else:
        print("usage: enroll_api.py {new-token NAME | revoke TOKEN | list}")
        sys.exit(2)
