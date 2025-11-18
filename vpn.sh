#!/usr/bin/env bash

set -Eeuo pipefail

# --- USER CONFIG -------------------------------------------------------------
VPN_SERVER="tc-vpn-1.vpn.umn.edu"
VPN_USER="username"
VPN_GROUP="AnyConnect-UofMvpnFull"
DUO_FACTOR="push"   # push | phone | sms | <6-digit code>
# -----------------------------------------------------------------------------

OS="$(uname -s)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found." >&2; exit 1; }; }

# Check dependencies based on OS
need openconnect
if [ "$OS" = "Linux" ]; then
  need ip
fi

# --- Determine which vpnc-script to use --------------------------------------
get_vpnc_script() {
  if [ "$OS" = "Darwin" ]; then
    # --- MACOS DETECTED ---
    # On macOS, we use the standard vpnc-script installed by Homebrew/MacPorts.
    local mac_paths=(
      "/opt/homebrew/etc/vpnc-script"
      "/usr/local/etc/vpnc-script"
      "/etc/vpnc/vpnc-script"
    )

    for path in "${mac_paths[@]}"; do
      if [ -x "$path" ]; then
        echo "$path"
        return 0
      fi
    done

    echo "ERROR: standard 'vpnc-script' not found." >&2
    echo "       Run: brew install vpnc-scripts" >&2
    exit 1

  else
    # --- LINUX DETECTED ---
    # Use the custom inline script logic
    local s; s="$(mktemp -p /tmp umn_vpnc.XXXXXX.sh)"
    cat >"$s" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/sbin:/sbin:/usr/bin:/bin
STATE_DIR="/run/umn-openconnect"
mkdir -p "$STATE_DIR"
VPNPID="${VPNPID:-$PPID}"
DEFROUTE="$STATE_DIR/defroute.$VPNPID"
ROUTES_INC="$STATE_DIR/routes-inc.$VPNPID"
ROUTES_EXC="$STATE_DIR/routes-exc.$VPNPID"
RESOLV_BAK="$STATE_DIR/resolv.$VPNPID"
ip4() { ip -4 "$@"; }
host_route_add() {
  local line dev via
  line="$(ip4 route get "$VPNGATEWAY" 2>/dev/null | head -n1 || true)"
  dev="$(awk '/ dev /{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}' <<<"$line")"
  via="$(awk '/ via /{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1);exit}}' <<<"$line")"
  [ -n "$dev" ] || return 0
  if [ -n "$via" ]; then ip4 route add "$VPNGATEWAY" via "$via" dev "$dev" 2>/dev/null || true
  else ip4 route add "$VPNGATEWAY" dev "$dev" 2>/dev/null || true
  fi
}
host_route_del() { ip4 route del "$VPNGATEWAY" 2>/dev/null || true; }
tun_up() {
  local mtu="${INTERNAL_IP4_MTU:-}"
  if [ -z "$mtu" ]; then
    local uplink; uplink="$(ip -4 route get "$VPNGATEWAY" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
    [ -n "$uplink" ] && mtu="$(ip link show dev "$uplink" | sed -n 's/.*mtu \([0-9]\+\).*/\1/p')"
    [ -n "${mtu:-}" ] && mtu=$((mtu-88)) || mtu=1412
  fi
  ip link set dev "$TUNDEV" up mtu "$mtu"
  ip4 addr add "$INTERNAL_IP4_ADDRESS/32" peer "$INTERNAL_IP4_ADDRESS" dev "$TUNDEV" 2>/dev/null || true
}
tun_down() {
  ip4 addr del "$INTERNAL_IP4_ADDRESS/32" dev "$TUNDEV" 2>/dev/null || true
  ip link set dev "$TUNDEV" down 2>/dev/null || true
}
routes_apply() {
  : >"$ROUTES_INC"; : >"$ROUTES_EXC"
  ip4 route show default >"$DEFROUTE" 2>/dev/null || true
  local exc_n="${CISCO_SPLIT_EXC:-0}"
  if [ "$exc_n" -gt 0 ]; then
    local dev via line net len
    for ((i=0;i<exc_n;i++)); do
      eval net="\${CISCO_SPLIT_EXC_${i}_ADDR}"
      eval len="\${CISCO_SPLIT_EXC_${i}_MASKLEN}"
      case "$net" in 0.*|127.*|169.254.*) continue ;; esac
      line="$(ip4 route get "$net" 2>/dev/null | head -n1 || true)"
      dev="$(awk '/ dev /{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}' <<<"$line")"
      via="$(awk '/ via /{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1);exit}}' <<<"$line")"
      if [ -n "$dev" ]; then
        if [ -n "$via" ]; then
          ip4 route add "$net/$len" via "$via" dev "$dev" 2>/dev/null || true
          echo "$net/$len via $via dev $dev" >>"$ROUTES_EXC"
        else
          ip4 route add "$net/$len" dev "$dev" 2>/dev/null || true
          echo "$net/$len dev $dev" >>"$ROUTES_EXC"
        fi
      fi
    done
  fi
  local inc_n="${CISCO_SPLIT_INC:-0}" net len
  if [ "$inc_n" -gt 0 ]; then
    for ((i=0;i<inc_n;i++)); do
      eval net="\${CISCO_SPLIT_INC_${i}_ADDR}"
      eval len="\${CISCO_SPLIT_INC_${i}_MASKLEN}"
      if [ "$net" = "0.0.0.0" ]; then
        ip4 route replace default dev "$TUNDEV" metric 1
      else
        ip4 route replace "$net/$len" dev "$TUNDEV"
        echo "$net/$len" >>"$ROUTES_INC"
      fi
    done
  else
    ip4 route replace default dev "$TUNDEV" metric 1
  fi
}
routes_revert() {
  if [ -s "$ROUTES_INC" ]; then
    while read -r pfx; do ip4 route del "$pfx" dev "$TUNDEV" 2>/dev/null || true; done <"$ROUTES_INC"
    rm -f "$ROUTES_INC"
  fi
  if [ -s "$ROUTES_EXC" ]; then
    while read -r line; do ip4 route del $line 2>/dev/null || true; done <"$ROUTES_EXC"
    rm -f "$ROUTES_EXC"
  fi
  if [ -s "$DEFROUTE" ]; then
    while read -r line; do ip4 route replace $line || true; done <"$DEFROUTE"
    rm -f "$DEFROUTE"
  else
    ip4 route del default dev "$TUNDEV" 2>/dev/null || true
  fi
}
dns_set() {
  [ -n "${INTERNAL_IP4_DNS:-}" ] || return 0
  if command -v resolvectl >/dev/null 2>&1 && readlink -f /etc/resolv.conf 2>/dev/null | grep -q '/run/systemd/resolve'; then
    resolvectl dns "$TUNDEV" $INTERNAL_IP4_DNS || true
    [ -n "${CISCO_DEF_DOMAIN:-}" ] && resolvectl domain "$TUNDEV" $CISCO_DEF_DOMAIN || true
  elif command -v resolvconf >/dev/null 2>&1; then
    {
      for ns in $INTERNAL_IP4_DNS; do echo "nameserver $ns"; done
      [ -n "${CISCO_DEF_DOMAIN:-}" ] && echo "search $CISCO_DEF_DOMAIN"
    } | resolvconf -a "$TUNDEV" || true
  else
    [ -f "$RESOLV_BAK" ] || cp -f /etc/resolv.conf "$RESOLV_BAK" 2>/dev/null || true
    {
      echo "# @UMN_OC_GENERATED"
      [ -n "${CISCO_DEF_DOMAIN:-}" ] && echo "search $CISCO_DEF_DOMAIN"
      for ns in $INTERNAL_IP4_DNS; do echo "nameserver $ns"; done
    } >/etc/resolv.conf
  fi
}
dns_unset() {
  if command -v resolvectl >/dev/null 2>&1 && readlink -f /etc/resolv.conf 2>/dev/null | grep -q '/run/systemd/resolve'; then
    resolvectl revert "$TUNDEV" 2>/dev/null || true
  elif command -v resolvconf >/dev/null 2>&1; then
    resolvconf -d "$TUNDEV" 2>/dev/null || true
  elif [ -f "$RESOLV_BAK" ]; then
    cp -f "$RESOLV_BAK" /etc/resolv.conf 2>/dev/null || true
    rm -f "$RESOLV_BAK"
  fi
}
case "${reason:-}" in
  pre-init) : ;;
  connect)
    host_route_add; tun_up; routes_apply; dns_set ;;
  disconnect)
    dns_unset; routes_revert; host_route_del; tun_down ;;
  attempt-reconnect)
    host_route_add ;;
  *) : ;;
esac
exit 0
EOS
    chmod +x "$s"
    echo "$s"
  fi
}

# --- TTY Setup ---------------------------------------------------------------
if [ ! -t 0 ] && [ -r /dev/tty ]; then
  exec </dev/tty
fi

# --- Get Script & Cleanup Setup ----------------------------------------------
INLINE_SCRIPT="$(get_vpnc_script)"
cleanup() { 
  if [ "$OS" = "Linux" ] && [ -n "${INLINE_SCRIPT:-}" ]; then 
    rm -f "$INLINE_SCRIPT"
  fi 
}
trap cleanup EXIT

# --- Credentials -------------------------------------------------------------
echo "Attempting to connect to UMN VPN (${VPN_GROUP}) on ${OS}..."
printf "Enter UMN Password (ONLY the password; Duo '%s' is auto-appended): " "$DUO_FACTOR"
IFS= read -r -s UMN_PASSWORD
echo
[ -z "${UMN_PASSWORD:-}" ] && { echo "No password entered. Aborting."; exit 1; }
PASSWD_WITH_DUO="${UMN_PASSWORD},${DUO_FACTOR}"
unset UMN_PASSWORD

echo "Escalating privileges (sudo)..."
if ! sudo -nv true 2>/dev/null; then
  sudo -k
  sudo -v -p "[sudo] password: " </dev/tty 1>/dev/tty 2>/dev/tty || { echo "sudo failed."; exit 1; }
fi

# --- Run OpenConnect ---------------------------------------------------------
echo "Connecting..."

{ printf '%s\n' "$PASSWD_WITH_DUO"; cat; } | sudo -n openconnect \
      --protocol=anyconnect \
      --user="$VPN_USER" \
      --authgroup="$VPN_GROUP" \
      --passwd-on-stdin \
      --force-dpd=90 \
      --no-dtls \
      --script="$INLINE_SCRIPT" \
      "$VPN_SERVER"
