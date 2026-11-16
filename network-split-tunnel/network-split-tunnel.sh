#!/usr/bin/env bash
# Split-tunnel manager for NetworkManager OpenConnect on Ubuntu.
# Default: VPN owns the default route. Iranian (and extra) prefixes
# use the Wi-Fi gateway. Docker and unrelated routes are never modified.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT/logs"
BACKUP_DIR="$ROOT/backup"
DATA_DIR="$ROOT/data"
TEMPLATE="$ROOT/templates/50-split-direct"
DISPATCHER="/etc/NetworkManager/dispatcher.d/50-split-direct"
DISPATCHER_FLAG="$BACKUP_DIR/dispatcher-installed.flag"

WIFI_IF_DEFAULT="wlp0s20f3"
WIFI_CON_DEFAULT="Pishgaman"
VPN_IF_DEFAULT="vpn0"
VPN_CON_DEFAULT="nl"
TABLE=200
PREF=10000
PROTO=252
TABLE_NAME="split-direct"

mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$DATA_DIR"
LOG="$LOG_DIR/main-$(date +%Y%m%d).log"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

run() {
  log "+ $*"
  if ! "$@"; then
    log "FAILED: $*"
    return 1
  fi
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    exec sudo -- "$0" "$@"
  fi
}

wifi_if() { echo "${WIFI_IF:-$WIFI_IF_DEFAULT}"; }
vpn_if() { echo "${VPN_IF:-$VPN_IF_DEFAULT}"; }

detect_wifi_gw() {
  local ifc
  ifc="$(wifi_if)"
  ip -4 route show default dev "$ifc" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

validate_underlay() {
  local ifc gw
  ifc="$(wifi_if)"
  ip link show "$ifc" >/dev/null 2>&1 || die "Wi-Fi interface $ifc not found"
  gw="$(detect_wifi_gw)"
  [[ -n "$gw" ]] || die "No default via on $ifc"
  ping -c 1 -W 2 -n "$gw" >/dev/null 2>&1 || log "WARN: ping gateway $gw failed (may lack cap_net_raw); continuing if ARP/route exists"
  log "underlay ok: $ifc gw=$gw"
}

vpn_is_up() {
  ip link show "$(vpn_if)" >/dev/null 2>&1 && ip -4 addr show "$(vpn_if)" | grep -q 'inet '
}

list_cidrs() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '/^[[:space:]]*#/ {next} NF {print $1}' "$f"
}

cmd_status() {
  echo "=== interfaces ==="
  ip -br addr
  echo "=== IPv4 routes (main) ==="
  ip -4 route show
  echo "=== IPv4 table $TABLE ==="
  ip -4 route show table "$TABLE" 2>/dev/null || echo "(none)"
  echo "=== rules ==="
  ip rule show
  echo "=== VPN ==="
  if vpn_is_up; then
    echo "vpn0 is UP $(ip -4 -o addr show "$(vpn_if)" | awk '{print $4}')"
    nmcli -t -f NAME,TYPE,DEVICE,STATE connection show --active | grep -E 'vpn|tun' || true
  else
    echo "VPN interface down"
  fi
  echo "=== DNS ==="
  resolvectl status 2>/dev/null | sed -n '1,80p'
  echo "=== dispatcher ==="
  if [[ -f "$DISPATCHER" ]]; then echo "installed: $DISPATCHER"; else echo "dispatcher not installed"; fi
  echo "=== latest backup ==="
  cat "$BACKUP_DIR/LATEST" 2>/dev/null || echo none
}

cmd_backup() {
  local ts dest
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$ts"
  if [[ -d "$dest" ]]; then
    die "backup $dest already exists; refusing to overwrite"
  fi
  mkdir -p "$dest"
  ip -4 route show >"$dest/ip4-route-main.txt"
  ip -6 route show >"$dest/ip6-route-main.txt"
  ip rule show >"$dest/ip-rule.txt"
  {
    echo "=== ip -4 addr ==="; ip -4 addr
    echo "=== ip -4 route table all ==="; ip -4 route show table all
    echo "=== ip rule ==="; ip rule show
  } >"$dest/ip-state.txt"
  nmcli -t connection show >"$dest/nm-connections.txt"
  nmcli connection show --active >"$dest/nm-active.txt"
  nmcli connection show "$WIFI_CON_DEFAULT" >"$dest/nm-Pishgaman.txt" 2>/dev/null || true
  nmcli connection show "$VPN_CON_DEFAULT" >"$dest/nm-nl.txt" 2>/dev/null || true
  resolvectl status >"$dest/resolvectl.txt" 2>/dev/null || true
  cp /etc/resolv.conf "$dest/resolv.conf"
  {
    echo "WIFI_IF=$(wifi_if)"
    echo "WIFI_GW=$(detect_wifi_gw)"
    echo "WIFI_SRC=$(ip -4 -o addr show "$(wifi_if)" | awk '{print $4}' | cut -d/ -f1 | head -1)"
    echo "VPN_IF=$(vpn_if)"
    echo "VPN_UP=$(vpn_is_up && echo yes || echo no)"
  } >"$dest/env.sh"
  echo "$ts" >"$BACKUP_DIR/LATEST"
  log "backup written $dest"
  echo "$dest"
}

cmd_plan() {
  local gw n_ir n_ex
  gw="$(detect_wifi_gw || true)"
  n_ir="$(list_cidrs "$DATA_DIR/ir-prefixes.txt" | wc -l)"
  n_ex="$(list_cidrs "$DATA_DIR/extra-cidrs.txt" | wc -l)"
  cat <<EOF
Planned changes (NOT applied):

1) Policy routing
   - Create routing table $TABLE ($TABLE_NAME)
   - ip rule add pref $PREF lookup $TABLE
   - For each prefix in data/ir-prefixes.txt ($n_ir lines) and
     data/extra-cidrs.txt ($n_ex lines):
       ip route replace PREFIX via ${gw:-<wifi-gw>} dev $(wifi_if) table $TABLE proto $PROTO
   - Default route on vpn0 stays metric 50 (all other traffic remains on VPN)

2) Split DNS (runtime, via systemd-resolved)
   - resolvectl dns $(wifi_if) 5.202.100.100 5.202.100.101
   - resolvectl domain $(wifi_if) '~ir'
   - resolvectl default-route $(wifi_if) no
   - VPN remains DefaultRoute DNS (8.8.8.8 / 8.8.4.4)

3) Persistence
   - Install NetworkManager dispatcher $DISPATCHER
   - On vpn-up: reapply table $TABLE
   - On vpn-down: flush table $TABLE and delete rule $PREF
   - Does not change OpenConnect gateway, credentials, or protocol
   - Does not change Docker bridges or iptables

4) Not planned until extra-cidrs.txt is uncommented
   - 185.114.188.24/32 (golestan) — TCP 80/443 timed out on VPN and Wi-Fi

Not changed: ipv4.never-default on VPN, NM connection UUIDs, VPN server
route 94.118.219.32, existing host routes to ISP DNS.

Populate IR prefixes (optional, no install):
  curl -fsSL https://www.ipdeny.com/ipblocks/data/aggregated/ir-aggregated.zone \\
    -o $DATA_DIR/ir-prefixes.txt
EOF
}

ensure_table_name() {
  local f=/etc/iproute2/rt_tables
  if [[ -f "$f" ]] && ! grep -qE "^[[:space:]]*$TABLE[[:space:]]+$TABLE_NAME[[:space:]]*$" "$f"; then
    if grep -qE "^[[:space:]]*$TABLE[[:space:]]" "$f"; then
      log "rt_tables already has id $TABLE; using numeric table id only"
    else
      echo "$TABLE $TABLE_NAME" >>"$f"
      log "added $TABLE $TABLE_NAME to $f"
    fi
  fi
}

apply_routes() {
  local gw ifc p
  ifc="$(wifi_if)"
  gw="$(detect_wifi_gw)"
  [[ -n "$gw" ]] || die "no wifi gateway"
  validate_underlay
  ensure_table_name
  if ip rule show | grep -qE "^${PREF}:"; then
    log "rule pref $PREF already present"
  else
    run ip rule add pref "$PREF" lookup "$TABLE"
  fi
  local count=0
  while read -r p; do
    [[ -z "$p" ]] && continue
    ip route replace "$p" via "$gw" dev "$ifc" table "$TABLE" proto "$PROTO" || die "failed route $p"
    count=$((count + 1))
  done < <( { list_cidrs "$DATA_DIR/ir-prefixes.txt"; list_cidrs "$DATA_DIR/extra-cidrs.txt"; } )
  log "installed $count prefixes into table $TABLE"
  if [[ $count -eq 0 ]]; then
    log "WARN: prefix lists are empty; VPN still carries all non-local traffic"
  fi
}

teardown_runtime() {
  if ip rule show | grep -qE "^${PREF}:"; then
    run ip rule del pref "$PREF" || true
  fi
  ip route flush table "$TABLE" 2>/dev/null || true
  log "runtime policy removed (VPN/Wi-Fi defaults untouched)"
}

split_dns() {
  local ifc
  ifc="$(wifi_if)"
  run resolvectl dns "$ifc" 5.202.100.100 5.202.100.101
  run resolvectl domain "$ifc" '~ir' '~ac.ir'
  run resolvectl default-route "$ifc" no
}

cmd_apply() {
  need_root "$@"
  [[ -x "$ROOT/rollback.sh" ]] || die "rollback.sh missing or not executable"
  [[ -f "$BACKUP_DIR/LATEST" ]] || die "no backup; run: $0 backup"
  local confirm_file="$ROOT/APPLY_CONFIRMED"
  if [[ "${SPLIT_TUNNEL_CONFIRM:-}" != "yes" && ! -f "$confirm_file" ]]; then
    die "refusing apply. Create $confirm_file or run: sudo SPLIT_TUNNEL_CONFIRM=yes $0 apply"
  fi
  validate_underlay
  vpn_is_up || log "WARN: VPN is down; routes will apply on next vpn-up if dispatcher is installed"
  apply_routes
  split_dns || log "WARN: split DNS configuration failed"
  if [[ ! -f "$DISPATCHER" ]]; then
    install -m 0755 "$TEMPLATE" "$DISPATCHER"
    date -Is >"$DISPATCHER_FLAG"
    log "installed dispatcher $DISPATCHER"
  else
    log "dispatcher already present"
  fi
  log "apply complete"
  cmd_status
}

cmd_test() {
  python3 - "$ROOT" <<'PY'
import socket, ssl, time, subprocess, sys, os

targets = [
    ("golestan.ikiu.ac.ir", 443),
    ("digikala.com", 443),
    ("google.com", 443),
]

def resolve(host):
    t0 = time.time()
    infos = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
    dt = (time.time() - t0) * 1000
    ip = infos[0][4][0]
    return ip, dt

def route_get(ip):
    out = subprocess.check_output(["ip", "route", "get", ip], text=True)
    return out.strip().splitlines()[0]

def http_head(host, ip, timeout=8):
    ctx = ssl.create_default_context()
    t0 = time.time()
    err = None
    code = None
    try:
        with socket.create_connection((ip, 443), timeout=timeout) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                req = f"HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
                s.sendall(req.encode())
                data = s.recv(256).decode("iso-8859-1", "replace")
                first = data.splitlines()[0] if data else ""
                parts = first.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    code = parts[1]
                else:
                    code = first or "no-status"
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
    dt = time.time() - t0
    return code, dt, err

print("=== split-tunnel connectivity test ===")
for host, port in targets:
    try:
        ip, dns_ms = resolve(host)
    except Exception as e:
        print(f"\n{host}: DNS FAILED {e}")
        continue
    rline = route_get(ip)
    via = "direct-wifi" if "wlp0s20f3" in rline else ("vpn" if "vpn0" in rline else "other")
    code, t, err = http_head(host, ip)
    print(f"\nhost={host}")
    print(f"  resolved_ip={ip}")
    print(f"  dns_ms={dns_ms:.1f}")
    print(f"  route={rline}")
    print(f"  path={via}")
    print(f"  http={code} time_s={t:.3f} error={err}")
PY
}

usage() {
  cat <<EOF
Usage: $0 <status|backup|plan|apply|rollback|test|reapply-runtime|teardown-runtime>

apply requires: a backup, executable rollback.sh, and
  SPLIT_TUNNEL_CONFIRM=yes sudo $0 apply
EOF
}

main() {
  local cmd="${1:-status}"
  shift || true
  case "$cmd" in
    status) cmd_status ;;
    backup) cmd_backup ;;
    plan) cmd_plan ;;
    apply) cmd_apply "$cmd" "$@" ;;
    rollback) exec "$ROOT/rollback.sh" ;;
    test) cmd_test ;;
    reapply-runtime)
      need_root reapply-runtime
      apply_routes
      split_dns || true
      ;;
    teardown-runtime)
      need_root teardown-runtime
      teardown_runtime
      ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
