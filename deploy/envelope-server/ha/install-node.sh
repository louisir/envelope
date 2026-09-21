#!/usr/bin/env bash
# Called by deploy-ha-apply.ps1. All mutations require an explicit phase.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run through sudo.' >&2; exit 1; }
stage=$(realpath "$1")
phase=$2
[[ $stage == /var/tmp/envelope-ha-stage-* ]] || { echo 'Unexpected stage path.' >&2; exit 1; }
source "$stage/node.env"
[[ $NODE_ID == s1 || $NODE_ID == s2 || $NODE_ID == q-gcp ]] || exit 1
stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup=/var/backups/envelope-ha/$stamp-$phase
mkdir -p "$backup"
chmod 700 "$backup"
preserve() { [[ ! -e $1 ]] || cp -a --parents "$1" "$backup/"; }
install_config() { preserve "$2"; install -o root -g "$3" -m "$4" "$1" "$2"; }

# Proxy rollback journal. Only explicitly recorded files below the Nginx root
# can be restored/deleted; existing directories and unrelated files are kept.
proxy_track_file() {
  local path=$1 index=${#proxy_paths[@]}
  [[ $path == "$proxy_root/"* && ! -d $path ]] || { echo "Unexpected proxy file: $path" >&2; return 1; }
  if [[ -e $path || -L $path ]]; then
    cp -a -- "$path" "$proxy_journal/$index"
    proxy_existed+=(1)
  else
    proxy_existed+=(0)
  fi
  proxy_paths+=("$path")
}
proxy_rollback() {
  local original_status=$1 failed=0 index path
  trap - EXIT HUP INT TERM
  set +e
  for ((index=${#proxy_paths[@]}-1; index>=0; index--)); do
    path=${proxy_paths[index]}
    if [[ -d $path && ! -L $path ]]; then
      echo "Refusing to remove unexpected directory during proxy rollback: $path" >&2
      failed=1
      continue
    fi
    # This exact path was journaled before the first write. Removing a symlink
    # removes the link itself, never its target; no recursive removal is used.
    if ! rm -f -- "$path"; then failed=1; continue; fi
    if [[ ${proxy_existed[index]} == 1 ]]; then
      cp -a -- "$proxy_journal/$index" "$path" || failed=1
    fi
  done
  for ((index=${#proxy_created_dirs[@]}-1; index>=0; index--)); do
    path=${proxy_created_dirs[index]}
    # A concurrent writer's files are not ours to delete.
    if [[ -d $path ]]; then rmdir -- "$path" || failed=1; fi
  done
  if ((failed)); then
    echo "Proxy rollback needs inspection; backups retained at $proxy_journal. No rollback reload attempted." >&2
  else
    echo "Proxy files restored to their prior state; backups retained at $proxy_journal. No rollback reload attempted." >&2
  fi
  exit "$original_status"
}
case "$phase" in
  prerequisites)
    # Package installation does not change existing application/proxy configurations.
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=l
    apt-get update
    apt-get install -y ca-certificates openssl iptables python3 curl
    if [[ $NODE_ID == s1 ]]; then apt-get install -y nginx certbot; fi
    ;;
  etcd)
    [[ $(uname -m) == x86_64 ]]
    echo "$ETCD_ARCHIVE_SHA256  $stage/etcd.tar.gz" | sha256sum -c -
    command -v iptables >/dev/null
    command -v ip6tables >/dev/null
    id envelope-etcd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/envelope-etcd --shell /usr/sbin/nologin envelope-etcd
    # A fresh install cannot overwrite or attempt to bootstrap an existing member.
    [[ ! -e /etc/envelope-ha/etcd.env && ! -e /var/lib/envelope-etcd/member ]] || { echo 'Existing etcd installation: use an explicit upgrade/recovery procedure.' >&2; exit 1; }
    install -d -o root -g root -m 755 /etc/envelope-ha /opt/envelope-etcd
    install -d -o root -g envelope-etcd -m 750 /etc/envelope-ha/etcd-pki
    install -d -o envelope-etcd -g envelope-etcd -m 700 /var/lib/envelope-etcd
    tar -xzf "$stage/etcd.tar.gz" -C /opt/envelope-etcd
    ln -s /opt/envelope-etcd/etcd-v3.6.14-linux-amd64 /opt/envelope-etcd/current
    for file in client-ca.crt peer-ca.crt etcd.crt etcd.key peer.crt peer.key; do
      install -o root -g envelope-etcd -m 640 "$stage/pki/$file" "/etc/envelope-ha/etcd-pki/$file"
    done
    install_config "$stage/node.env" /etc/envelope-ha/node.env root 600
    install_config "$stage/etcd.env" /etc/envelope-ha/etcd.env envelope-etcd 640
    install_config "$stage/firewall.sh" /usr/local/sbin/envelope-ha-firewall root 750
    install_config "$stage/envelope-ha-firewall.service" /etc/systemd/system/envelope-ha-firewall.service root 644
    install_config "$stage/envelope-etcd.service" /etc/systemd/system/envelope-etcd.service root 644
    systemctl daemon-reload
    systemctl enable --now envelope-ha-firewall.service
    systemctl enable envelope-etcd.service
    # Starting all three voters sequentially must not wait for each to form a quorum.
    systemctl start --no-block envelope-etcd.service
    ;;
  runtime)
    [[ $NODE_ID != q-gcp ]]
    [[ -f "$stage/envelope-server-ha" ]] || { echo 'Linux envelope-server-ha binary missing.' >&2; exit 1; }
    [[ -f /etc/envelope-ha/etcd.env ]]
    id envelope >/dev/null 2>&1 || useradd --system --home-dir /var/lib/envelope-ha --shell /usr/sbin/nologin envelope
    install -d -o root -g envelope -m 750 /etc/envelope-ha/app-pki
    install -d -o envelope -g envelope -m 700 /var/lib/envelope-ha
    install -d -o root -g root -m 755 /opt/envelope-ha/releases
    release=/opt/envelope-ha/releases/$stamp
    [[ ! -e "$release" ]]
    mkdir "$release"
    install -o root -g root -m 755 "$stage/envelope-server-ha" "$release/envelope-server-ha"
    if [[ -f "$stage/envelope-ha-recovery" ]]; then
      install -o root -g root -m 755 "$stage/envelope-ha-recovery" "$release/envelope-ha-recovery"
      "$release/envelope-ha-recovery" --help >/dev/null
    fi
    "$release/envelope-server-ha" --help >/dev/null
    # Stop only this application's service, then use SQLite backup rather than copying an open WAL database.
    systemctl stop envelope-ha.service 2>/dev/null || true
    if [[ -e /var/lib/envelope-ha/envelope.sqlite3 ]]; then
      python3 - /var/lib/envelope-ha/envelope.sqlite3 "$backup/envelope.sqlite3" <<'PY'
import sqlite3,sys
source=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
target=sqlite3.connect(sys.argv[2]); source.backup(target)
assert target.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
target.close(); source.close()
PY
    fi
    preserve /opt/envelope-ha/current
    for file in client-ca.crt app.crt app.key; do
      install_config "$stage/pki/$file" "/etc/envelope-ha/app-pki/$file" envelope 640
    done
    for file in cluster.json runtime.json signing-secret; do install_config "$stage/$file" "/etc/envelope-ha/$file" envelope 640; done
    install_config "$stage/envelope-ha.service" /etc/systemd/system/envelope-ha.service root 644
    ln -s "$release" /opt/envelope-ha/current.next
    mv -Tf /opt/envelope-ha/current.next /opt/envelope-ha/current
    systemctl daemon-reload
    systemctl enable --now envelope-ha.service
    ;;
  acme)
    [[ $NODE_ID == s1 ]]
    # DNS must already resolve to S1 and public TCP 80 must be reachable.
    account=(--register-unsafely-without-email)
    if [[ -n ${3:-} ]]; then
      [[ $3 =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || { echo 'Invalid ACME email.' >&2; exit 1; }
      account=(--email "$3")
    fi
    command -v nginx >/dev/null
    install -d -m 755 /var/lib/envelope-acme/.well-known/acme-challenge
    [[ ! -e /etc/nginx/sites-available/envelope-ha-http.conf ]] || { echo 'HTTP site already exists; inspect before retry.' >&2; exit 1; }
    cat > /etc/nginx/sites-available/envelope-ha-http.conf <<EOF
server {
    listen 80;
    server_name $PUBLIC_DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root /var/lib/envelope-acme; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    ln -s /etc/nginx/sites-available/envelope-ha-http.conf /etc/nginx/sites-enabled/envelope-ha-http.conf
    nginx -t
    systemctl reload nginx
    certbot certonly --non-interactive --agree-tos "${account[@]}" --webroot -w /var/lib/envelope-acme -d "$PUBLIC_DOMAIN"
    install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nnginx -t && systemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/envelope-ha-reload
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/envelope-ha-reload
    ;;
  proxy)
    [[ $NODE_ID != q-gcp ]]
    [[ -f /etc/letsencrypt/live/$PUBLIC_DOMAIN/fullchain.pem && -f /etc/letsencrypt/live/$PUBLIC_DOMAIN/privkey.pem ]]
    command -v nginx >/dev/null
    nginx -t
    proxy_root=/etc/nginx
    proxy_journal=$backup/proxy-journal
    proxy_paths=()
    proxy_existed=()
    proxy_created_dirs=()
    install -d -m 700 "$proxy_journal"
    # EXIT also handles explicit exit guards and failed Python edits, while the
    # signal handlers route ordinary interruptions through the same rollback.
    trap 'proxy_exit=$?; if ((proxy_exit != 0)); then proxy_rollback "$proxy_exit"; fi' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for directory in /etc/nginx/snippets /etc/nginx/conf.d; do
      [[ $(readlink -m "$directory") == "$proxy_root/"* ]] || { echo 'Nginx directory resolves outside its root.' >&2; exit 1; }
      if [[ ! -d $directory ]]; then
        [[ ! -e $directory && ! -L $directory ]] || { echo 'Unexpected Nginx directory type.' >&2; exit 1; }
        proxy_created_dirs+=("$directory")
        install -d -m 755 "$directory"
      fi
    done
    proxy_track_file /etc/nginx/snippets/envelope-v2.conf
    install_config "$stage/nginx-public-v2.conf" /etc/nginx/snippets/envelope-v2.conf root 644
    proxy_track_file /etc/nginx/conf.d/envelope-v2-limits.conf
    install_config "$stage/nginx-http-limits.conf" /etc/nginx/conf.d/envelope-v2-limits.conf root 644
    proxy_track_file /etc/nginx/conf.d/envelope-internal.conf
    install_config "$stage/nginx-internal.conf" /etc/nginx/conf.d/envelope-internal.conf root 644
    if [[ $NODE_ID == s1 ]]; then
      target=/etc/nginx/sites-available/envelope-ha-https.conf
      [[ ! -e "$target" && ! -L "$target" ]] || { echo 'HTTPS site already exists; inspect before update.' >&2; exit 1; }
      proxy_track_file "$target"
      cat > "$target" <<EOF
server {
    listen 443 ssl http2;
    server_name $PUBLIC_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$PUBLIC_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PUBLIC_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    include /etc/nginx/snippets/envelope-v2.conf;
    location / { return 404; }
}
EOF
      [[ ! -e /etc/nginx/sites-enabled/envelope-ha-https.conf && ! -L /etc/nginx/sites-enabled/envelope-ha-https.conf ]] || { echo 'HTTPS link already exists; inspect before update.' >&2; exit 1; }
      proxy_track_file /etc/nginx/sites-enabled/envelope-ha-https.conf
      ln -s "$target" /etc/nginx/sites-enabled/envelope-ha-https.conf
    else
      target=$(readlink -f /etc/nginx/sites-enabled/yourturn-https.conf)
      [[ $target == "$proxy_root/"* && -f $target ]] || { echo 'Unexpected YourTurn site target.' >&2; exit 1; }
      proxy_track_file "$target"
      preserve "$target"
      # Refuse unexpected structure; never rewrite the public 443 stream configuration.
      python3 - "$target" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); text=p.read_text()
if 'include /etc/nginx/snippets/envelope-v2.conf;' in text:
    raise SystemExit('Envelope include already exists; inspect before update')
if len(re.findall(r'\bserver\s*\{',text))!=1 or '127.0.0.1:9443' not in text:
    raise SystemExit('Unexpected YourTurn HTTPS server structure')
pattern=r'(?m)^(\s*server_name\s+npvwxzkfdqkck\.work\s+www\.npvwxzkfdqkck\.work\s*;)'
text,count=re.subn(pattern,r'\1\n    include /etc/nginx/snippets/envelope-v2.conf;',text)
if count!=1: raise SystemExit('Expected server_name not unique')
p.write_text(text)
PY
    fi
    # Any failure above or in validation restores every journaled file. Reload
    # is attempted only after validation; rollback itself never reloads Nginx.
    nginx -t
    systemctl reload nginx
    trap - EXIT HUP INT TERM
    ;;
  verify)
    systemctl is-active envelope-etcd.service envelope-ha-firewall.service
    /opt/envelope-etcd/current/etcd --version | head -n 1
    ss -lnt '( sport = :2379 or sport = :2380 or sport = :19093 or sport = :19094 or sport = :19444 )'
    if [[ $NODE_ID != q-gcp ]]; then
      systemctl is-active envelope-ha.service
      curl --fail --silent --show-error http://127.0.0.1:19093/v2/health
      printf '\n'
      nginx -t
    fi
    ;;
  *) echo 'Unknown phase.' >&2; exit 1 ;;
esac
echo "Phase $phase complete on $NODE_ID. Preservation directory: $backup"
