#!/usr/bin/env bash
# Set up the SPT-VPN enrollment service on Ubuntu/Debian.
#
# Run as root. Idempotent.
#
#   ./install-server.sh
#
# After running:
#   1. Edit /etc/spt-vpn/config.json with your real WG public key,
#      endpoint, reserved_ips, etc.
#   2. systemctl restart spt-vpn-enroll
#   3. Note the SHA256 fingerprint printed at the end of this script
#      and pass it to `client/build.ps1 -EnrollFingerprint` when
#      building the client installer.
#   4. Create invite tokens:
#        sudo -u spt-vpn /opt/spt-vpn/venv/bin/python \
#             /opt/spt-vpn/enroll_api.py new-token alice
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must run as root" >&2; exit 1
fi

APP_DIR=/opt/spt-vpn
CONF_DIR=/etc/spt-vpn
CERT_DIR=/etc/spt-vpn/tls
WG_CONF=/etc/wireguard/wg0.conf

# Public address used as the cert's CN/SAN. Override with EXPOSED_ADDR env.
EXPOSED_ADDR="${EXPOSED_ADDR:-$(curl -fsS https://api.ipify.org 2>/dev/null || echo localhost)}"

apt-get update
apt-get install -y wireguard wireguard-tools python3-venv python3-pip nginx openssl curl

# --- Service user ------------------------------------------------------------
id spt-vpn >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin spt-vpn
mkdir -p "$APP_DIR" "$CONF_DIR" "$CERT_DIR"

# --- App files ---------------------------------------------------------------
install -m 0644 "$(dirname "$0")/enroll_api.py" "$APP_DIR/enroll_api.py"

if [[ ! -f "$CONF_DIR/config.json" ]]; then
  install -m 0640 "$(dirname "$0")/config.example.json" "$CONF_DIR/config.json"
  echo ">>> wrote $CONF_DIR/config.json - EDIT IT BEFORE STARTING THE SERVICE"
fi
[[ -f "$CONF_DIR/invites.json" ]] || echo '{"tokens":{}}' > "$CONF_DIR/invites.json"
# manifest.json is uploaded later by the host PC publisher; create an
# empty placeholder so the service starts cleanly.
[[ -f "$CONF_DIR/manifest.json" ]] || echo '{"required":[],"optional":[]}' > "$CONF_DIR/manifest.json"

chown -R spt-vpn:spt-vpn "$APP_DIR" "$CONF_DIR"
chmod 0640 "$CONF_DIR/invites.json" "$CONF_DIR/config.json" "$CONF_DIR/manifest.json"

# --- Python venv -------------------------------------------------------------
if [[ ! -d "$APP_DIR/venv" ]]; then
  python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --upgrade pip >/dev/null
"$APP_DIR/venv/bin/pip" install flask waitress >/dev/null
chown -R spt-vpn:spt-vpn "$APP_DIR/venv"

# --- wg/wg-quick wrappers + sudoers -----------------------------------------
cat > /etc/sudoers.d/spt-vpn <<'EOF'
spt-vpn ALL=(root) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick
EOF
chmod 0440 /etc/sudoers.d/spt-vpn

cat > /usr/local/bin/wg <<'EOF'
#!/bin/sh
exec sudo /usr/bin/wg "$@"
EOF
cat > /usr/local/bin/wg-quick <<'EOF'
#!/bin/sh
exec sudo /usr/bin/wg-quick "$@"
EOF
chmod 0755 /usr/local/bin/wg /usr/local/bin/wg-quick

# --- wg0.conf marker block ---------------------------------------------------
# Preserve any hand-added peers (e.g. Sunshine). Just ensure the managed
# block markers exist so enroll_api can edit between them.
if [[ -f "$WG_CONF" ]]; then
  if ! grep -q "spt-vpn managed peers" "$WG_CONF"; then
    {
      echo ""
      echo "# >>> spt-vpn managed peers (do not edit by hand) >>>"
      echo "# <<< spt-vpn managed peers <<<"
    } >> "$WG_CONF"
    echo ">>> injected managed-peer markers into $WG_CONF"
  fi
else
  echo ">>> $WG_CONF does not exist. Create it from wg0.conf.example before starting wg-quick@wg0."
fi
touch "$WG_CONF"
chgrp spt-vpn "$WG_CONF"
chmod 0660 "$WG_CONF"

# --- Self-signed TLS cert ----------------------------------------------------
CRT="$CERT_DIR/server.crt"
KEY="$CERT_DIR/server.key"
if [[ ! -f "$CRT" || ! -f "$KEY" ]]; then
  echo ">>> generating self-signed TLS cert for $EXPOSED_ADDR"
  # Build a SAN line that supports both IP and DNS.
  if [[ "$EXPOSED_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN="IP:$EXPOSED_ADDR"
  else
    SAN="DNS:$EXPOSED_ADDR"
  fi
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$KEY" -out "$CRT" \
    -subj "/CN=$EXPOSED_ADDR" \
    -addext "subjectAltName=$SAN" >/dev/null 2>&1
  chmod 0600 "$KEY"
  chmod 0644 "$CRT"
fi

# --- systemd unit ------------------------------------------------------------
cat > /etc/systemd/system/spt-vpn-enroll.service <<EOF
[Unit]
Description=SPT-VPN enrollment API
After=network.target wg-quick@wg0.service

[Service]
User=spt-vpn
Group=spt-vpn
Environment=ENROLL_CONFIG=$CONF_DIR/config.json
Environment=ENROLL_INVITES=$CONF_DIR/invites.json
Environment=MANIFEST_PATH=$CONF_DIR/manifest.json
Environment=WG_CONF=$WG_CONF
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/waitress-serve --listen=127.0.0.1:8765 enroll_api:app
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# --- nginx reverse proxy with self-signed cert ------------------------------
cat > /etc/nginx/sites-available/spt-vpn <<EOF
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     $CRT;
    ssl_certificate_key $KEY;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 1m;

    location / {
        proxy_pass http://127.0.0.1:8765;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 30s;
    }
}
EOF
ln -sf /etc/nginx/sites-available/spt-vpn /etc/nginx/sites-enabled/spt-vpn
rm -f /etc/nginx/sites-enabled/default

systemctl daemon-reload
systemctl enable --now spt-vpn-enroll
nginx -t
systemctl reload nginx || systemctl restart nginx

# --- Firewall ---------------------------------------------------------------
# Ubuntu's UFW defaults to deny inbound. The Azure NSG is a separate layer
# and is not enough on its own - if UFW is active we must open 443 here too.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 443/tcp comment 'spt-vpn enroll API' >/dev/null
    echo "UFW: opened 443/tcp"
fi

# --- Final report ------------------------------------------------------------
FP=$(openssl x509 -in "$CRT" -noout -fingerprint -sha256 | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')

echo
echo "================================================================="
echo " SPT-VPN enrollment service installed."
echo "================================================================="
echo " Public URL    : https://$EXPOSED_ADDR/"
echo " SHA256 finger : $FP"
echo
echo " Next steps:"
echo "   1. Edit $CONF_DIR/config.json (server_pubkey, endpoint,"
echo "      reserved_ips, server_vpn_ip, pool_cidr, client_allowed_ips)."
echo "   2. systemctl restart spt-vpn-enroll"
echo "   3. Create an invite token:"
echo "        sudo -u spt-vpn $APP_DIR/venv/bin/python $APP_DIR/enroll_api.py new-token alice"
echo "   4. Build the client installer on Windows with:"
echo "        .\\build.ps1 -EnrollUrl https://$EXPOSED_ADDR \\"
echo "                    -EnrollFingerprint $FP"
echo "   5. Upload manifest.json from your host PC with publish-mods.ps1."
echo
