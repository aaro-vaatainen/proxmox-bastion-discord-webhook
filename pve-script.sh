#!/usr/bin/env bash
set -euo pipefail

# Prevent overlapping runs
exec 9>/run/pve-wol-watch.lock
flock -n 9 || exit 0

CONF="/etc/pve-wol-watch.conf"
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

PING_COUNT=3
PING_TIMEOUT=1

COOLDOWN=300                 # min time between WOL sends per node
ALERT_AFTER_SECS=600         # 10 min offline -> alert once per incident

STATE_DIR="/var/lib/pve-wol"
LOG_TAG="pve-wol-watch"
mkdir -p "$STATE_DIR"

NODES=(
  "pve4 172.16.67.4 98:e7:f4:f2:af:7e"
  "pve5 172.16.67.5 80:ce:62:2f:6a:d6"
  "pve6 172.16.67.6 98:e7:f4:ee:c2:00"
)

log() {
  echo "[$(date -Is)] $*"
  logger -t "$LOG_TAG" -- "$*"
}

discord_post() {
  local msg="$1"
  [[ -z "$DISCORD_WEBHOOK_URL" ]] && return 0

  # Escape for JSON (minimal but safe enough)
  local esc
  esc=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')

  curl -sS -X POST \
    -H "Content-Type: application/json" \
    -d "{\"content\":\"$esc\"}" \
    "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

is_up() {
  local ip="$1"
  ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" >/dev/null 2>&1
}

now_epoch() { date +%s; }

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

for entry in "${NODES[@]}"; do
  read -r NAME IP MAC <<<"$entry"

  STAMP_WOL="$STATE_DIR/${NAME}.last_wol"
  STAMP_INCIDENT_START="$STATE_DIR/${NAME}.incident_start"
  STAMP_ALERTED="$STATE_DIR/${NAME}.alerted_10min"

  if is_up "$IP"; then
    log "$NAME OK (ping $IP)"

    # recovery notifications if we had an incident
    if [[ -f "$STAMP_INCIDENT_START" ]]; then
      discord_post "✅ [$HOSTNAME_SHORT] $NAME ($IP) is back online."
      rm -f "$STAMP_INCIDENT_START" "$STAMP_ALERTED"
    fi

    continue
  fi

  # offline
  log "$NAME DOWN (no ping $IP)"

  # start incident timestamp if not present
  if [[ ! -f "$STAMP_INCIDENT_START" ]]; then
    now_epoch >"$STAMP_INCIDENT_START"
    discord_post "⚠️ [$HOSTNAME_SHORT] $NAME ($IP) is OFFLINE (ping failed)."
  fi

  # send WOL with cooldown
  now=$(now_epoch)
  last_wol=0
  [[ -f "$STAMP_WOL" ]] && last_wol=$(cat "$STAMP_WOL" 2>/dev/null || echo 0)

  if (( now - last_wol >= COOLDOWN )); then
    log "$NAME sending WOL to $MAC"
    discord_post "🔌 [$HOSTNAME_SHORT] Sending WOL to $NAME ($IP) MAC $MAC"
    if wakeonlan "$MAC" >/dev/null 2>&1; then
      echo "$now" >"$STAMP_WOL"
    else
      discord_post "❌ [$HOSTNAME_SHORT] WOL send FAILED for $NAME ($IP) MAC $MAC"
    fi
  else
    log "$NAME WOL cooldown active (${now-last_wol}s < ${COOLDOWN}s)"
  fi

  # if still offline after 10 minutes from incident start, alert once
  start=$(cat "$STAMP_INCIDENT_START" 2>/dev/null || echo "$now")
  if (( now - start >= ALERT_AFTER_SECS )) && [[ ! -f "$STAMP_ALERTED" ]]; then
    echo "$now" >"$STAMP_ALERTED"
    discord_post "🚨 [$HOSTNAME_SHORT] $NAME ($IP) is STILL OFFLINE after ${ALERT_AFTER_SECS}s (10 min)."
  fi
done
