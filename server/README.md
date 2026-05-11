# Server (Azure VM)

## Initial install

```bash
sudo EXPOSED_ADDR=<your.vm.public.ip> ./install-server.sh
```

Provisions:
- `wireguard` + `wireguard-tools`
- Python venv at `/opt/spt-vpn/venv` with Flask + waitress
- Self-signed TLS cert at `/etc/spt-vpn/tls/` (10-year validity)
- nginx reverse proxy on `:443` -> `127.0.0.1:8765`
- systemd unit `spt-vpn-enroll.service`
- Sudoers wrappers so the `spt-vpn` user can run `wg` / `wg-quick`
- Adds the managed-peer marker block to `/etc/wireguard/wg0.conf`
  without touching hand-added peers

After install:

1. Edit `/etc/spt-vpn/config.json` with your real values:
   - `endpoint`: `<public_ip_or_host>:51820`
   - `server_pubkey`: contents of `/etc/wireguard/server.pub`
   - `server_vpn_ip`: usually `10.8.0.1`
   - `pool_cidr`: e.g. `10.8.0.0/24`
   - `client_allowed_ips`: VPN destinations the client routes through
     the tunnel. Usually `10.8.0.2/32` so friends only reach your PC.
   - `reserved_ips`: IPs already in use (server, your PC, existing
     Sunshine/RustDesk peers).
2. `sudo systemctl restart spt-vpn-enroll`
3. Note the SHA256 fingerprint printed at the end of the install script;
   pass it to `client/build.ps1 -EnrollFingerprint`.

## Creating invite tokens

```bash
sudo -u spt-vpn /opt/spt-vpn/venv/bin/python \
    /opt/spt-vpn/enroll_api.py new-token alice
```

Prints a 32-char token. Send it to the friend along with
`SptVpnSetup.exe`.

## Revoking a token

```bash
sudo -u spt-vpn /opt/spt-vpn/venv/bin/python \
    /opt/spt-vpn/enroll_api.py revoke <token>
```

Strips the peer from `wg0.conf`, runs `wg syncconf`. Friend's tunnel
stops working within seconds.

## Listing all invites

```bash
sudo -u spt-vpn /opt/spt-vpn/venv/bin/python \
    /opt/spt-vpn/enroll_api.py list
```

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | /health | none | liveness probe |
| POST | /enroll | Bearer | client posts pubkey, gets assigned IP + server pubkey/endpoint |
| GET | /manifest | Bearer | returns `manifest.json` uploaded by the publisher |

## Files

| Path | Purpose |
|---|---|
| `/opt/spt-vpn/enroll_api.py` | Flask app |
| `/opt/spt-vpn/venv/` | Python venv |
| `/etc/spt-vpn/config.json` | Service config |
| `/etc/spt-vpn/invites.json` | Tokens (per-token: name, assigned IP, pubkey) |
| `/etc/spt-vpn/manifest.json` | Mod manifest (uploaded by publisher) |
| `/etc/spt-vpn/tls/server.crt` + `.key` | Self-signed TLS cert |
| `/etc/systemd/system/spt-vpn-enroll.service` | systemd unit |
| `/etc/nginx/sites-enabled/spt-vpn` | nginx reverse proxy |
| `/etc/wireguard/wg0.conf` | WireGuard interface (managed-peer block) |

## Operations

```bash
# logs
sudo journalctl -u spt-vpn-enroll -n 50 --no-pager

# current peer status
sudo wg show wg0

# regenerate TLS cert (e.g. for a new IP)
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/spt-vpn/tls/server.key \
    -out   /etc/spt-vpn/tls/server.crt \
    -subj "/CN=<ip>" -addext "subjectAltName=IP:<ip>"
sudo systemctl reload nginx
# Note the new fingerprint and rebuild the client installer:
sudo openssl x509 -in /etc/spt-vpn/tls/server.crt \
    -noout -fingerprint -sha256 | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f'
```
