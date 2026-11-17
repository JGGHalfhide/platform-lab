#!/usr/bin/env bash
# Direct Ethernet link from the build host to the airgapped node (the iMac).
#
#   scripts/airgap-link.sh status|share|cut|uncut
#   (make airgap-link-status / airgap-link-share / airgap-link-cut / airgap-link-uncut)
#
# share  NetworkManager profile `airgap-link` on LINK_IF (default eno1):
#        ipv4.method shared, 192.168.50.1/24. NM runs DHCP and DNS (dnsmasq)
#        on the link and NATs it out through the host's internet connection
#        (Wi-Fi), so the node can install OS packages during setup.
# cut    Keeps the link, DHCP and DNS (the node keeps its address and the
#        build host can still reach it), but drops anything the node sends
#        beyond the link: an nftables table `airgap_link` with a forward rule.
#        The node's own firewalld egress block (make airgap-disconnect) goes
#        on top.
# uncut  Removes that table.
#
# Never touches any other interface or profile. In particular enp3s0 /
# "Wired connection 2" (Raspberry Pi wake-on-LAN) is left alone.
# Subnet 192.168.50.0/24 avoids the pod/service CIDRs (10.42/16, 10.43/16),
# libvirt (192.168.122/24) and the home LAN.
set -euo pipefail

LINK_IF="${LINK_IF:-eno1}"
PROFILE="${PROFILE:-airgap-link}"
ADDR="${ADDR:-192.168.50.1/24}"
NET="${ADDR%.*}.0/24"
NFT_TABLE=airgap_link
# Optional fixed DHCP address for the node (NODE_MAC and NODE_ADDR), so the
# inventory address does not change: a dnsmasq option for NM's shared mode.
NODE_MAC="${NODE_MAC:-}"
NODE_ADDR="${NODE_ADDR:-}"
DNSMASQ_CONF=/etc/NetworkManager/dnsmasq-shared.d/airgap-link.conf

[[ "$LINK_IF" != enp3s0 ]] || { echo "refusing to touch enp3s0 (Pi wake-on-LAN link)" >&2; exit 1; }

status() {
  echo "==> $LINK_IF"
  ip -br link show "$LINK_IF"
  ip -br -4 addr show "$LINK_IF"
  nmcli -f GENERAL.CONNECTION device show "$LINK_IF" | sed 's/^/    /'
  echo "==> DHCP leases on the link"
  lease="/var/lib/NetworkManager/dnsmasq-$LINK_IF.leases"
  if sudo test -f "$lease"; then sudo cat "$lease" | awk '{print "    " $3, $2, $4}'; else echo "    (none)"; fi
  echo "==> cut: $(sudo nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && echo yes || echo no)"
}

share() {
  if ! nmcli -t -f NAME con show | grep -qx "$PROFILE"; then
    echo "==> Creating NM profile $PROFILE on $LINK_IF ($ADDR, shared)"
    sudo nmcli con add type ethernet con-name "$PROFILE" ifname "$LINK_IF" \
      ipv4.method shared ipv4.addresses "$ADDR" ipv6.method disabled \
      connection.autoconnect yes connection.autoconnect-priority 10 >/dev/null
  else
    echo "==> NM profile $PROFILE exists"
    sudo nmcli con modify "$PROFILE" ifname "$LINK_IF" ipv4.method shared \
      ipv4.addresses "$ADDR" ipv6.method disabled \
      connection.autoconnect yes connection.autoconnect-priority 10
  fi
  if [[ -n "$NODE_MAC" && -n "$NODE_ADDR" ]]; then
    want="dhcp-host=$NODE_MAC,$NODE_ADDR,airgap-node-01"
    if ! sudo grep -qx "$want" "$DNSMASQ_CONF" 2>/dev/null; then
      echo "==> Reserving $NODE_ADDR for $NODE_MAC"
      echo "$want" | sudo install -D -m 0644 /dev/stdin "$DNSMASQ_CONF"
    fi
  fi
  sudo nmcli con up "$PROFILE" >/dev/null
  status
}

cut() {
  echo "==> Blocking forwarding from $LINK_IF ($NET) beyond the link"
  sudo nft -f - <<EOF
table inet $NFT_TABLE
delete table inet $NFT_TABLE
table inet $NFT_TABLE {
  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    iifname "$LINK_IF" oifname != "$LINK_IF" counter reject with icmpx admin-prohibited
    oifname "$LINK_IF" iifname != "$LINK_IF" ct state new counter reject with icmpx admin-prohibited
  }
}
EOF
  status
}

uncut() {
  sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  status
}

case "${1:-status}" in
  status) status ;;
  share) share ;;
  cut) cut ;;
  uncut) uncut ;;
  *) echo "usage: $0 status|share|cut|uncut" >&2; exit 1 ;;
esac
