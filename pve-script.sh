#!/usr/bin/env bash
set -euo pipefail

# Prevent overlapping runs
exec 9>/run/pve-wol-watch.lock
flock -n 9 || exit 0

# Defaults (can be overridden from /etc/pve-wol-watch.conf)
DISCORD_WEBHOOK_URL=""
DISCORD_USERNAME="PVE Bastion Watchdog"
DISCORD_LOGO_URL="https://i.imgur.com/zlKIds2.png"

PING_COUNT=1
PING_TIMEOUT=1

WOL_SUCCESS_WINDOW=600 # if node returns within this many seconds after last WOL => "WOL success"

# Offline notice stages: now, 10 min, 1h, 24h
OFFLINE_NOTIFY_SCHEDULE=(0 600 3600 86400)
# WOL attempts: 1 min, 10 min, 30 min from incident start
WOL_SCHEDULE=(60 600 1800)

STATE_DIR="/var/lib/pve-wol"
LOG_TAG="pve-wol-watch"

NODES=(
  "pve4 172.16.67.4 98:e7:f4:f2:af:7e"
  "pve5 172.16.67.5 80:ce:62:2f:6a:d6"
  "pve6 172.16.67.6 98:e7:f4:ee:c2:00"
)

CONF="/etc/pve-wol-watch.conf"
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

mkdir -p "$STATE_DIR"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

log() {
  echo "[$(date -Is)] $*"
  logger -t "$LOG_TAG" -- "$*"
}

now_epoch() { date +%s; }

now_iso_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

format_duration_compact() {
  local seconds="$1"
  if (( seconds % 86400 == 0 )); then
    printf '%d day(s)' "$((seconds / 86400))"
  elif (( seconds % 3600 == 0 )); then
    printf '%d hour(s)' "$((seconds / 3600))"
  elif (( seconds % 60 == 0 )); then
    printf '%d minute(s)' "$((seconds / 60))"
  else
    printf '%d second(s)' "$seconds"
  fi
}

join_names() {
  local out=""
  local item
  for item in "$@"; do
    if [[ -n "$out" ]]; then
      out+=", "
    fi
    out+="$item"
  done
  printf '%s' "$out"
}

discord_embed() {
  local color="$1"
  local title="$2"
  local description="$3"

  [[ -z "$DISCORD_WEBHOOK_URL" ]] && return 0

  local esc_title esc_desc esc_user esc_logo esc_host ts payload
  esc_title="$(json_escape "$title")"
  esc_desc="$(json_escape "$description")"
  esc_user="$(json_escape "$DISCORD_USERNAME")"
  esc_logo="$(json_escape "$DISCORD_LOGO_URL")"
  esc_host="$(json_escape "$HOSTNAME_SHORT")"
  ts="$(now_iso_utc)"

  payload=$(cat <<JSON
{"username":"$esc_user","avatar_url":"$esc_logo","embeds":[{"title":"$esc_title","description":"$esc_desc","color":$color,"thumbnail":{"url":"$esc_logo"},"footer":{"text":"$esc_host"},"timestamp":"$ts"}]}
JSON
)

  curl -sS -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

is_up() {
  local ip="$1"
  ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" >/dev/null 2>&1
}

read_int_file() {
  local file="$1"
  local default_value="$2"

  if [[ -f "$file" ]]; then
    local value
    value=$(cat "$file" 2>/dev/null || echo "$default_value")
    if [[ "$value" =~ ^-?[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return
    fi
  fi

  printf '%s\n' "$default_value"
}

clear_node_incident_state() {
  local name="$1"
  rm -f \
    "$STATE_DIR/${name}.incident_start" \
    "$STATE_DIR/${name}.notify_stage" \
    "$STATE_DIR/${name}.wol_stage" \
    "$STATE_DIR/${name}.last_wol"
}

node_offline_message() {
  local stage="$1"
  local name="$2"
  local ip="$3"

  case "$stage" in
    0)
      printf 'Node **%s** (%s) on **%s** is offline.' "$name" "$ip" "$HOSTNAME_SHORT"
      ;;
    1)
      printf 'Node **%s** (%s) has been offline for **10 minutes**.' "$name" "$ip"
      ;;
    2)
      printf 'Node **%s** (%s) has been offline for **1 hour**.' "$name" "$ip"
      ;;
    3)
      printf 'Node **%s** (%s) has been offline for **24 hours**. No further offline reminders for this incident.' "$name" "$ip"
      ;;
  esac
}

cluster_offline_message() {
  local stage="$1"
  local offline_count="$2"
  local names="$3"

  case "$stage" in
    0)
      printf 'Cluster degradation detected on **%s**: **%s** nodes offline (%s).' "$HOSTNAME_SHORT" "$offline_count" "$names"
      ;;
    1)
      printf 'Cluster degradation persists for **10 minutes**: **%s** nodes offline (%s).' "$offline_count" "$names"
      ;;
    2)
      printf 'Cluster degradation persists for **1 hour**: **%s** nodes offline (%s).' "$offline_count" "$names"
      ;;
    3)
      printf 'Cluster degradation persists for **24 hours**: **%s** nodes offline (%s). No further cluster reminders for this incident.' "$offline_count" "$names"
      ;;
  esac
}

send_staged_node_offline_notification() {
  local name="$1"
  local ip="$2"
  local duration="$3"
  local stage_file="$4"

  local stage threshold next_stage
  stage="$(read_int_file "$stage_file" -1)"

  next_stage=$((stage + 1))
  if (( next_stage >= ${#OFFLINE_NOTIFY_SCHEDULE[@]} )); then
    return
  fi

  threshold=${OFFLINE_NOTIFY_SCHEDULE[$next_stage]}
  if (( duration >= threshold )); then
    local msg
    msg="$(node_offline_message "$next_stage" "$name" "$ip")"
    discord_embed 15158332 "🔴 Node Offline" "$msg"
    echo "$next_stage" >"$stage_file"
  fi
}

send_staged_cluster_offline_notification() {
  local duration="$1"
  local stage_file="$2"
  local offline_count="$3"
  local names="$4"

  local stage threshold next_stage
  stage="$(read_int_file "$stage_file" -1)"

  next_stage=$((stage + 1))
  if (( next_stage >= ${#OFFLINE_NOTIFY_SCHEDULE[@]} )); then
    return
  fi

  threshold=${OFFLINE_NOTIFY_SCHEDULE[$next_stage]}
  if (( duration >= threshold )); then
    local msg
    msg="$(cluster_offline_message "$next_stage" "$offline_count" "$names")"
    discord_embed 15548997 "🟠 Cluster Offline" "$msg"
    echo "$next_stage" >"$stage_file"
  fi
}

send_scheduled_wol() {
  local name="$1"
  local mac="$2"
  local duration="$3"
  local wol_stage_file="$4"
  local last_wol_file="$5"

  local wol_stage
  wol_stage="$(read_int_file "$wol_stage_file" 0)"

  if (( wol_stage >= ${#WOL_SCHEDULE[@]} )); then
    return
  fi

  local threshold
  threshold=${WOL_SCHEDULE[$wol_stage]}

  if (( duration < threshold )); then
    return
  fi

  local now
  now="$(now_epoch)"

  if wakeonlan "$mac" >/dev/null 2>&1; then
    echo "$now" >"$last_wol_file"
    log "$name WOL sent (stage $((wol_stage + 1)) at ${duration}s)"
  else
    log "$name WOL send failed (stage $((wol_stage + 1)) at ${duration}s)"
  fi

  echo "$((wol_stage + 1))" >"$wol_stage_file"
}

offline_nodes=()

for entry in "${NODES[@]}"; do
  read -r name ip mac <<<"$entry"

  stamp_incident_start="$STATE_DIR/${name}.incident_start"
  stamp_notify_stage="$STATE_DIR/${name}.notify_stage"
  stamp_wol_stage="$STATE_DIR/${name}.wol_stage"
  stamp_last_wol="$STATE_DIR/${name}.last_wol"

  if is_up "$ip"; then
    if [[ -f "$stamp_incident_start" ]]; then
      now="$(now_epoch)"
      last_wol="$(read_int_file "$stamp_last_wol" 0)"

      if (( last_wol > 0 )) && (( now - last_wol <= WOL_SUCCESS_WINDOW )); then
        wol_elapsed_text="$(format_duration_compact "$((now - last_wol))")"
        wol_window_text="$(format_duration_compact "$WOL_SUCCESS_WINDOW")"
        discord_embed 5763719 "🟢 Node Online (WOL Success)" "Node **$name** ($ip) is back online **$wol_elapsed_text** after WOL (success window: **$wol_window_text**)."
      else
        discord_embed 3066993 "✅ Node Online" "Node **$name** ($ip) is back online."
      fi

      clear_node_incident_state "$name"
      log "$name recovered"
    fi

    continue
  fi

  offline_nodes+=("$name")
  now="$(now_epoch)"

  if [[ ! -f "$stamp_incident_start" ]]; then
    echo "$now" >"$stamp_incident_start"
    echo "-1" >"$stamp_notify_stage"
    echo "0" >"$stamp_wol_stage"
    echo "0" >"$stamp_last_wol"
    log "$name incident started"
  fi

  start="$(read_int_file "$stamp_incident_start" "$now")"
  duration=$((now - start))

  send_staged_node_offline_notification "$name" "$ip" "$duration" "$stamp_notify_stage"
  send_scheduled_wol "$name" "$mac" "$duration" "$stamp_wol_stage" "$stamp_last_wol"

done

# Cluster-level incident handling (2+ nodes offline)
cluster_incident_start="$STATE_DIR/cluster.incident_start"
cluster_notify_stage="$STATE_DIR/cluster.notify_stage"

if (( ${#offline_nodes[@]} >= 2 )); then
  now="$(now_epoch)"

  if [[ ! -f "$cluster_incident_start" ]]; then
    echo "$now" >"$cluster_incident_start"
    echo "-1" >"$cluster_notify_stage"
    log "cluster incident started (${#offline_nodes[@]} nodes offline)"
  fi

  start="$(read_int_file "$cluster_incident_start" "$now")"
  duration=$((now - start))

  offline_csv="$(join_names "${offline_nodes[@]}")"
  send_staged_cluster_offline_notification "$duration" "$cluster_notify_stage" "${#offline_nodes[@]}" "$offline_csv"
else
  if [[ -f "$cluster_incident_start" ]]; then
    discord_embed 3066993 "✅ Cluster Recovered" "Cluster on **$HOSTNAME_SHORT** is recovered (fewer than 2 nodes offline)."
    rm -f "$cluster_incident_start" "$cluster_notify_stage"
    log "cluster recovered"
  fi
fi
