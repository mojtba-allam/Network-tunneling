#!/usr/bin/env bash
# Independent rollback: restore the network policy introduced by this
# split-tunnel project. Does NOT delete pre-existing routes (Docker,
# VPN default, Wi-Fi default, VPN server host route, ISP DNS host routes).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/rollback-$(date +%Y%m%d-%H%M%S).log"
BACKUP_LATEST="$ROOT/backup/LATEST"
TABLE=200
PREF=10000
PROTO=252
DISPATCHER="/etc/NetworkManager/dispatcher.d/50-split-direct"
DISPATCHER_STATE="$ROOT/backup/dispatcher-installed.flag"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    exec sudo -- "$0" "$@"
  fi
}

restore_existing_dns_host_routes() {
  local gw=100.69.128.1
  local dev=wlp0s20f3
  for ip in 5.202.100.100 5.202.100.101; do
    if ! ip -4 route show "$ip/32" | grep -q .; then
      log "restore pre-existing host route $ip via $gw"
      ip route add "$ip/32" via "$gw" dev "$dev" || log "WARN: failed to restore $ip"
    else
      log "keep existing host route $ip"
    fi
  done
}

remove_our_policy() {
  if ip rule show | grep -q "pref $PREF"; then
    log "delete ip rule pref $PREF"
    ip rule del pref "$PREF" || log "WARN: rule delete failed"
  else
    log "no ip rule pref $PREF"
  fi
  if [[ -e /etc/iproute2/rt_tables ]] && grep -qE "[[:space:]]$TABLE[[:space:]]+split-direct$" /etc/iproute2/rt_tables; then
    log "note: rt_tables entry split-direct left in place (harmless); not removing shared system file content automatically beyond our line"
  fi
  if ip route show table "$TABLE" 2>/dev/null | grep -q .; then
    log "flush routing table $TABLE"
    ip route flush table "$TABLE"
  else
    log "table $TABLE already empty or absent"
  fi
  local our
  our="$(ip -4 route show proto "$PROTO" 2>/dev/null || true)"
  if [[ -n "$our" ]]; then
    log "delete proto $PROTO routes in main:"
    log "$our"
    ip route show proto "$PROTO" | while read -r dest rest; do
      [[ -z "${dest:-}" ]] && continue
      ip route del "$dest" proto "$PROTO" 2>/dev/null || ip route del $dest $rest 2>/dev/null || log "WARN: could not delete $dest $rest"
    done
  else
    log "no proto $PROTO routes in main"
  fi
}

remove_dispatcher() {
  if [[ -f "$DISPATCHER_STATE" && -f "$DISPATCHER" ]]; then
    log "remove dispatcher $DISPATCHER"
    rm -f "$DISPATCHER"
    rm -f "$DISPATCHER_STATE"
  elif [[ -f "$DISPATCHER" ]]; then
    log "dispatcher exists but was not flagged as installed by this project; leaving it"
  else
    log "dispatcher not installed"
  fi
}

reset_resolved_wifi_scope() {
  if command -v resolvectl >/dev/null; then
    if ip link show wlp0s20f3 >/dev/null 2>&1; then
      log "clear runtime split-DNS on wlp0s20f3 (VPN DNS remains default)"
      resolvectl revert wlp0s20f3 2>/dev/null || log "WARN: resolvectl revert wlp0s20f3 failed"
    fi
  fi
}

main() {
  need_root "$@"
  log "rollback start; latest backup marker: $(cat "$BACKUP_LATEST" 2>/dev/null || echo none)"
  if [[ -f "$ROOT/backup/$BACKUP_TS/ip4-route-main.txt" ]]; then
    :
  fi
  local ts
  ts="$(cat "$BACKUP_LATEST" 2>/dev/null || true)"
  if [[ -n "$ts" && -f "$ROOT/backup/$ts/ip4-route-main.txt" ]]; then
    log "reference backup $ROOT/backup/$ts/ip4-route-main.txt"
  fi
  remove_our_policy
  restore_existing_dns_host_routes
  reset_resolved_wifi_scope
  remove_dispatcher
  log "rollback complete"
  ip -4 route show
  ip rule show
}

main "$@"
