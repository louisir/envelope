#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENVELOPE_SERVER_BINARY="${ENVELOPE_SERVER_BINARY:-$REPO_ROOT/target/release/envelope-server}"
ENVELOPE_SERVER_ADMIN_BINARY="${ENVELOPE_SERVER_ADMIN_BINARY:-$REPO_ROOT/target/release/envelope-server-admin}"
ENVELOPE_SERVER_USER="${ENVELOPE_SERVER_USER:-envelope-server}"
ENVELOPE_SERVER_GROUP="${ENVELOPE_SERVER_GROUP:-$ENVELOPE_SERVER_USER}"
ENVELOPE_SERVER_BIND="${ENVELOPE_SERVER_BIND:-127.0.0.1:19093}"
ENVELOPE_SERVER_DATABASE="${ENVELOPE_SERVER_DATABASE:-/var/lib/envelope-server/envelope-server.sqlite3}"
ENVELOPE_SERVER_DOMAIN="${ENVELOPE_SERVER_DOMAIN:-}"
ENVELOPE_SERVER_INSTALL_DIR="${ENVELOPE_SERVER_INSTALL_DIR:-/opt/envelope-server}"
ENVELOPE_SERVER_CONFIG_DIR="${ENVELOPE_SERVER_CONFIG_DIR:-/etc/envelope-server}"
ENVELOPE_SERVER_NODE_MANIFEST="${ENVELOPE_SERVER_NODE_MANIFEST:-}"
ENVELOPE_SERVER_MANIFEST_PUBLIC_KEY="${ENVELOPE_SERVER_MANIFEST_PUBLIC_KEY:-}"
ENVELOPE_SERVER_NODE_ID="${ENVELOPE_SERVER_NODE_ID:-}"
ENVELOPE_SERVER_NODE_SIGNING_SECRET_FILE="${ENVELOPE_SERVER_NODE_SIGNING_SECRET_FILE:-}"
ENVELOPE_SERVER_DATA_DIR="$(dirname "$ENVELOPE_SERVER_DATABASE")"

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[|&\\]/\\&/g'
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root, for example: sudo $0" >&2
  exit 1
fi

if [[ ! -f "$ENVELOPE_SERVER_BINARY" ]]; then
  echo "envelope-server binary not found: $ENVELOPE_SERVER_BINARY" >&2
  echo "Build it first: cargo build --release -p envelope-server" >&2
  exit 1
fi

if ! getent group "$ENVELOPE_SERVER_GROUP" >/dev/null; then
  groupadd --system "$ENVELOPE_SERVER_GROUP"
fi

if ! id -u "$ENVELOPE_SERVER_USER" >/dev/null 2>&1; then
  useradd --system \
    --gid "$ENVELOPE_SERVER_GROUP" \
    --home-dir /var/lib/envelope-server \
    --shell /usr/sbin/nologin \
    "$ENVELOPE_SERVER_USER"
fi

install -d -m 0755 "$ENVELOPE_SERVER_INSTALL_DIR"
install -m 0755 "$ENVELOPE_SERVER_BINARY" "$ENVELOPE_SERVER_INSTALL_DIR/envelope-server"
if [[ -f "$ENVELOPE_SERVER_ADMIN_BINARY" ]]; then
  install -m 0755 "$ENVELOPE_SERVER_ADMIN_BINARY" "$ENVELOPE_SERVER_INSTALL_DIR/envelope-server-admin"
fi

install -d -m 0750 -o "$ENVELOPE_SERVER_USER" -g "$ENVELOPE_SERVER_GROUP" "$ENVELOPE_SERVER_DATA_DIR"
install -d -m 0755 "$ENVELOPE_SERVER_CONFIG_DIR"
cat >"$ENVELOPE_SERVER_CONFIG_DIR/envelope-server.env" <<EOF
ENVELOPE_SERVER_BIND=$ENVELOPE_SERVER_BIND
ENVELOPE_SERVER_DATABASE=$ENVELOPE_SERVER_DATABASE
EOF
if [[ -n "$ENVELOPE_SERVER_NODE_MANIFEST" ]]; then
  printf 'ENVELOPE_SERVER_NODE_MANIFEST=%s\n' "$ENVELOPE_SERVER_NODE_MANIFEST" >>"$ENVELOPE_SERVER_CONFIG_DIR/envelope-server.env"
fi
if [[ -n "$ENVELOPE_SERVER_MANIFEST_PUBLIC_KEY" ]]; then
  printf 'ENVELOPE_SERVER_MANIFEST_PUBLIC_KEY=%s\n' "$ENVELOPE_SERVER_MANIFEST_PUBLIC_KEY" >>"$ENVELOPE_SERVER_CONFIG_DIR/envelope-server.env"
fi
if [[ -n "$ENVELOPE_SERVER_NODE_ID" ]]; then
  printf 'ENVELOPE_SERVER_NODE_ID=%s\n' "$ENVELOPE_SERVER_NODE_ID" >>"$ENVELOPE_SERVER_CONFIG_DIR/envelope-server.env"
fi
if [[ -n "$ENVELOPE_SERVER_NODE_SIGNING_SECRET_FILE" ]]; then
  printf 'ENVELOPE_SERVER_NODE_SIGNING_SECRET_FILE=%s\n' "$ENVELOPE_SERVER_NODE_SIGNING_SECRET_FILE" >>"$ENVELOPE_SERVER_CONFIG_DIR/envelope-server.env"
fi
chmod 0644 "$ENVELOPE_SERVER_CONFIG_DIR/envelope-server.env"

sed \
  -e "s|{ENVELOPE_SERVER_USER}|$(escape_sed_replacement "$ENVELOPE_SERVER_USER")|g" \
  -e "s|{ENVELOPE_SERVER_GROUP}|$(escape_sed_replacement "$ENVELOPE_SERVER_GROUP")|g" \
  -e "s|{ENVELOPE_SERVER_INSTALL_DIR}|$(escape_sed_replacement "$ENVELOPE_SERVER_INSTALL_DIR")|g" \
  -e "s|{ENVELOPE_SERVER_CONFIG_DIR}|$(escape_sed_replacement "$ENVELOPE_SERVER_CONFIG_DIR")|g" \
  -e "s|{ENVELOPE_SERVER_DATA_DIR}|$(escape_sed_replacement "$ENVELOPE_SERVER_DATA_DIR")|g" \
  "$SCRIPT_DIR/envelope-server.service" \
  >/etc/systemd/system/envelope-server.service
chmod 0644 /etc/systemd/system/envelope-server.service

systemctl daemon-reload
systemctl enable envelope-server
systemctl restart envelope-server

if [[ -n "$ENVELOPE_SERVER_DOMAIN" ]]; then
  if ! command -v caddy >/dev/null 2>&1; then
    echo "ENVELOPE_SERVER_DOMAIN was set, but caddy is not installed. Install Caddy, then rerun this script." >&2
    exit 1
  else
    install -d -m 0755 /etc/caddy/conf.d
    sed "s|{ENVELOPE_SERVER_DOMAIN}|$(escape_sed_replacement "$ENVELOPE_SERVER_DOMAIN")|g" \
      "$SCRIPT_DIR/Caddyfile.template" \
      >/etc/caddy/conf.d/envelope-server.caddy

    if [[ ! -f /etc/caddy/Caddyfile ]]; then
      printf 'import /etc/caddy/conf.d/*.caddy\n' >/etc/caddy/Caddyfile
    elif ! grep -q 'import /etc/caddy/conf.d/\*.caddy' /etc/caddy/Caddyfile; then
      cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"
      printf '\nimport /etc/caddy/conf.d/*.caddy\n' >>/etc/caddy/Caddyfile
    fi

    caddy validate --config /etc/caddy/Caddyfile
    systemctl reload caddy
  fi
fi

systemctl --no-pager --full status envelope-server
