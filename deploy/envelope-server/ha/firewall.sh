#!/usr/bin/env bash
set -euo pipefail
# Only our three TCP ports enter our chain. Never flush or replace host rules.
source /etc/envelope-ha/node.env
rules=$(mktemp)
trap 'rm -f "$rules"' EXIT
printf '*filter\n:ENVELOPE_HA - [0:0]\n-F ENVELOPE_HA\n-A ENVELOPE_HA -i lo -j ACCEPT\n' > "$rules"
for address in 121.199.52.175 67.230.178.13 34.3.107.22; do
  printf -- '-A ENVELOPE_HA -p tcp -s %s -m multiport --dports 2379,2380 -j ACCEPT\n' "$address" >> "$rules"
done
if [[ -n "$PEER_IP" ]]; then
  printf -- '-A ENVELOPE_HA -p tcp -s %s --dport 19444 -j ACCEPT\n' "$PEER_IP" >> "$rules"
fi
printf -- '-A ENVELOPE_HA -j DROP\nCOMMIT\n' >> "$rules"
# Commit replacement of our own chain atomically; the existing chain is never temporarily empty.
iptables-restore -w --noflush < "$rules"
iptables -w -C INPUT -p tcp -m multiport --dports 2379,2380,19444 -j ENVELOPE_HA 2>/dev/null ||
  iptables -w -I INPUT 1 -p tcp -m multiport --dports 2379,2380,19444 -j ENVELOPE_HA
# Backends and etcd bind IPv4 only; explicitly prevent accidental IPv6 publication.
printf '*filter\n:ENVELOPE_HA - [0:0]\n-F ENVELOPE_HA\n-A ENVELOPE_HA -i lo -j ACCEPT\n-A ENVELOPE_HA -j DROP\nCOMMIT\n' | ip6tables-restore -w --noflush
ip6tables -w -C INPUT -p tcp -m multiport --dports 2379,2380,19444 -j ENVELOPE_HA 2>/dev/null ||
  ip6tables -w -I INPUT 1 -p tcp -m multiport --dports 2379,2380,19444 -j ENVELOPE_HA
