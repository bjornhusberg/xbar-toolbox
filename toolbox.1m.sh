#!/bin/bash
# <xbar.title>Toolbox</xbar.title>
# <xbar.desc>Gear menu: headset settings via headsetcontrol, and running keymap.</xbar.desc>
# <xbar.dependencies>headsetcontrol</xbar.dependencies>
# <xbar.var>string(VAR_GHE_HOST=""): GitHub Enterprise host for the notification badge. Leave empty to disable.</xbar.var>

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SIDETONE="$HOME/bin/sidetone"
KEYMAP="$HOME/bin/keymap"
COPILOT="$HOME/bin/copilot-aic"
CONFIG_DIR="$HOME/.config/xbar-toolbox"
CACHE_DIR="$CONFIG_DIR/cache"
HIDE_FLAG="$CONFIG_DIR/.hide-all"  # present = toolbar shows only the battery
CACHE_TTL=900        # composite icon: 15 minutes
COPILOT_TTL=600      # copilot data: 10 minutes
COPILOT_ICON_MIN_PCT=25  # show the toolbar donut from this daily usage percentage
AUDIO_DEVICE_TTL=30  # audio device name: 30 seconds
COPILOT_PCT_CACHE="$CACHE_DIR/copilot_pct"
COPILOT_STATS_CACHE="$CACHE_DIR/copilot_stats.txt"
AUDIO_DEVICE_CACHE="$CACHE_DIR/audio_device"
NOTIF_CACHE="$CACHE_DIR/notifications.tsv"
NOTIF_TTL=60         # unread GHE notifications: 1 minute
NOTIF_HOST="${VAR_GHE_HOST:-}"

mkdir -p "$CACHE_DIR"

# Actions are run by xbar as: toolbox.sh run <args...>
if [ "$1" = "run" ]; then
  shift
  case "$1" in
    sidetone) "$SIDETONE" "$2" ;;
    keymap) "$KEYMAP" ;;
    wifi)
      networksetup -setairportnetwork en0 "$2" "$(security find-generic-password -s xbar-wifi -a "$2" -w)" ;;
    wifi-disconnect)
      swift - <<'SWIFT'
import CoreWLAN
CWWiFiClient.shared().interface()?.disassociate()
SWIFT
      ;;
    lock)
      # Private login.framework call
      swift - <<'SWIFT'
import Foundation
guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
      let symbol = dlsym(handle, "SACLockScreenImmediate") else { exit(1) }
typealias LockScreen = @convention(c) () -> Void
unsafeBitCast(symbol, to: LockScreen.self)()
SWIFT
      ;;
    mute) osascript -e "set volume with output muted" ;;
    unmute) osascript -e "set volume without output muted" ;;
    lowpower)
      osascript -e "do shell script \"pmset -a lowpowermode $2\" with administrator privileges" ;;
    awake)
      if [ "$(osascript -e 'tell application "Amphetamine" to session is active')" = "true" ]; then
        osascript -e 'tell application "Amphetamine" to end session'
      else
        osascript -e 'tell application "Amphetamine" to start new session'
      fi ;;
    ghclear)
      # Marks every notification on host $2 as read, then empties the local list so the icon goes away.
      GH_HOST="$2" gh api --method PUT notifications >/dev/null && : > "$NOTIF_CACHE" ;;
    teams)
      # AppleScript needs the Automation permission for xbar; fall back to plain open without it.
      # Failures are kept in $CACHE_DIR/action.log, since click actions otherwise discard their output.
      osascript -e 'tell application id "com.microsoft.teams2" to activate' 2>>"$CACHE_DIR/action.log" \
        || open -b com.microsoft.teams2 2>>"$CACHE_DIR/action.log" ;;
    hide)
      if [ -f "$HIDE_FLAG" ]; then rm -f "$HIDE_FLAG"; else : > "$HIDE_FLAG"; fi ;;
  esac >/dev/null 2>&1
  exit 0
fi

# --- State detection --------------------------------------------------------

is_amphetamine_active() {
  if pgrep -x -u "$(id -u)" Amphetamine >/dev/null 2>/dev/null; then
    [ "$(osascript -e 'tell application "Amphetamine" to session is active' 2>/dev/null)" = "true" ]
    return $?
  fi
  return 1
}

# Returns "battery-{level}" or "none"
get_battery_state() {
  pmout=$(pmset -g batt 2>/dev/null)
  battery_percent=$(echo "$pmout" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
  if [ -z "$battery_percent" ]; then
    echo "none"  # no battery (desktop Mac)
    return
  fi
  level=$(( (battery_percent + 5) / 10 * 10 ))
  # Plugged in counts as charging, including when full or holding at a limit.
  if echo "$pmout" | grep -q "'AC Power'"; then
    echo "charging-$level"
  else
    echo "battery-$level"
  fi
}

# Returns "hotspot", "disconnected", or "connected"
get_wifi_state() {
  if [ "$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')" = "172.20.10.1" ]; then
    echo "hotspot"
  elif ipconfig getsummary en0 2>/dev/null | grep -q "SSID :"; then
    echo "connected"
  else
    echo "disconnected"
  fi
}

# Prints the current audio output device class: speaker | headphones
detect_audio_device() {
  local device
  device=$(swift - <<'SWIFT' 2>/dev/null
import CoreAudio
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var id: AudioDeviceID = 0; var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id)
addr.mSelector = kAudioObjectPropertyName; sz = UInt32(MemoryLayout<CFString>.size)
var ref: Unmanaged<CFString>? = nil
AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &ref)
print(ref?.takeRetainedValue() as String? ?? "")
SWIFT
)
  case "$device" in
    *MacBook*|*Built*in*|*Speaker*|"") echo "speaker" ;;
    *) echo "headphones" ;;
  esac
}

# Returns "none" (muted), "speaker" or "headphones".
# Muted check is always live. Device name uses stale-while-revalidate (TTL 30s).
get_audio_state() {
  if [ "$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)" = "true" ]; then
    echo "none"; return
  fi
  local age
  if [ -f "$AUDIO_DEVICE_CACHE" ]; then
    age=$(( $(date +%s) - $(stat -f%m "$AUDIO_DEVICE_CACHE") ))
    if [ "$age" -lt "$AUDIO_DEVICE_TTL" ]; then
      cat "$AUDIO_DEVICE_CACHE"; return  # fresh
    fi
    # Stale: serve immediately, refresh in background
    cat "$AUDIO_DEVICE_CACHE"
    (detect_audio_device > "${AUDIO_DEVICE_CACHE}.tmp" \
      && mv "${AUDIO_DEVICE_CACHE}.tmp" "$AUDIO_DEVICE_CACHE") &
    disown $!
  else
    # First run: block
    detect_audio_device | tee "$AUDIO_DEVICE_CACHE"
  fi
}

# Fetches Copilot AIC data into cache files. Non-blocking: triggers background
# refresh on cache miss and returns immediately using whatever is cached.
get_copilot_data() {
  if [ -f "$COPILOT_PCT_CACHE" ] \
      && [ $(( $(date +%s) - $(stat -f%m "$COPILOT_PCT_CACHE") )) -lt $COPILOT_TTL ]; then
    return  # fresh
  fi
  # Ensure cache files exist so callers can read them while we refresh
  [ -f "$COPILOT_PCT_CACHE" ]   || printf '' > "$COPILOT_PCT_CACHE"
  [ -f "$COPILOT_STATS_CACHE" ] || printf '' > "$COPILOT_STATS_CACHE"
  (
    local output first_line percentage
    output=$("$COPILOT" --xbar 2>/dev/null)
    first_line=$(echo "$output" | head -1)
    if [[ "$first_line" == percentage=* ]]; then
      percentage="${first_line#percentage=}"
      # The toolbar donut is only drawn from COPILOT_ICON_MIN_PCT usage; the stats rows always show.
      awk -v p="$percentage" -v min="$COPILOT_ICON_MIN_PCT" 'BEGIN { exit !(p + 0 >= min) }' || percentage=""
      echo "$percentage" > "${COPILOT_PCT_CACHE}.tmp" \
        && mv "${COPILOT_PCT_CACHE}.tmp" "$COPILOT_PCT_CACHE"
      echo "$output" | tail -n +3 \
        > "${COPILOT_STATS_CACHE}.tmp" \
        && mv "${COPILOT_STATS_CACHE}.tmp" "$COPILOT_STATS_CACHE"
    else
      printf '' > "$COPILOT_PCT_CACHE"
      printf '' > "$COPILOT_STATS_CACHE"
    fi
  ) &
  disown $!
}

# Unread GitHub Enterprise notifications, cached as "title<TAB>repo<TAB>web url".
# Non-blocking: refreshes in the background when the cache is stale.
get_notifications() {
  [ -n "$NOTIF_HOST" ] || return
  if [ -f "$NOTIF_CACHE" ] \
      && [ $(( $(date +%s) - $(stat -f%m "$NOTIF_CACHE") )) -lt $NOTIF_TTL ]; then
    return  # fresh
  fi
  [ -f "$NOTIF_CACHE" ] || printf '' > "$NOTIF_CACHE"
  (
    local out
    if out=$(GH_HOST="$NOTIF_HOST" gh api notifications --jq \
        '.[] | [.subject.title, .repository.full_name, (.subject.url // "")] | @tsv' 2>/dev/null); then
      echo "$out" | sed -E 's#https://[^/]+/(api/v3/)?repos/([^/]+/[^/]+)/pulls/#https://'"$NOTIF_HOST"'/\2/pull/#; s#https://[^/]+/(api/v3/)?repos/([^/]+/[^/]+)/issues/#https://'"$NOTIF_HOST"'/\2/issues/#' \
        | sed '/^$/d' > "${NOTIF_CACHE}.tmp" \
        && mv "${NOTIF_CACHE}.tmp" "$NOTIF_CACHE"
    else
      touch "$NOTIF_CACHE"  # keep the old list, retry after the TTL
    fi
  ) &
  disown $!
}

# Prints "<availability><TAB><unread count>" for the signed-in Teams account, or nothing.
# Read from the latest Teams log, where the first account entry is the main one.
# Teams reports PresenceUnknown that should be ignored ([^P])
get_teams_state() {
  pgrep -x -u "$(id -u)" MSTeams >/dev/null 2>&1 || return
  local logdir="$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library/Application Support/Logs"
  local log line
  while IFS= read -r log; do
    line=$(tail -c 300000 "$log" 2>/dev/null | grep -a "BroadcastGlobalState.*availability: [^P].*unread notification count" | tail -1)
    [ -n "$line" ] && break
  done < <(ls -t "$logdir"/MSTeams_*.log 2>/dev/null | head -2)
  [ -n "$line" ] || return
  # Teams logs the state at least every 5 minutes, so anything older is stale. Its log timestamps do not
  # match the system clock, so compare the state line with the last line of the same file, and use the
  # file's mtime to see that Teams is still writing.
  local logged last
  [ $(( $(date +%s) - $(stat -f%m "$log") )) -lt 600 ] || return
  last=$(tail -n 1 "$log" | cut -c1-19)
  logged=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${line:0:19}" +%s 2>/dev/null) || return
  last=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$last" +%s 2>/dev/null) || return
  [ $(( last - logged )) -lt 600 ] || return
  local state
  state=$(echo "$line" | sed -nE 's/^[^{]*\{ availability: ([^P][A-Za-z]+), unread notification count: ([0-9]+) \}.*/\1\t\2/p')
  echo "$state"
}

# Returns composite icon as base64. Uses stale-while-revalidate (TTL 15 min).
get_icon() {
  local amph_active="$1" battery_state="$2" wifi_state="$3" \
        audio_state="$4" copilot_pct="$5" notif_active="$6" teams_badge="$7"
  local cache_key="bar"

  [ "$teams_badge"  != "none"         ] && cache_key="${cache_key}-teams-${teams_badge}"
  [ "$notif_active"  = "true"         ] && cache_key="${cache_key}-notif"
  [ "$amph_active"   = "true"         ] && cache_key="${cache_key}-coffee"
  [ "$wifi_state"    = "disconnected" ] && cache_key="${cache_key}-wifi"
  [ "$wifi_state"    = "hotspot"      ] && cache_key="${cache_key}-hotspot"
  [ "$audio_state"  != "none"         ] && cache_key="${cache_key}-${audio_state}"
  if [ -n "$copilot_pct" ]; then
    cache_key="${cache_key}-copilot-$(printf "%.0f" "$copilot_pct")"
  fi
  [ "$battery_state" != "none" ] && cache_key="${cache_key}-${battery_state}"

  local cache_file="$CACHE_DIR/${cache_key}.b64"
  local age

  if [ -f "$cache_file" ]; then
    age=$(( $(date +%s) - $(stat -f%m "$cache_file") ))
    if [ "$age" -lt "$CACHE_TTL" ]; then
      cat "$cache_file"; return  # fresh
    fi
    # Stale: serve immediately, regenerate in background
    cat "$cache_file"
    ("$CONFIG_DIR/render-icon" "$amph_active" "$battery_state" "$wifi_state" \
        "$audio_state" "${copilot_pct:-0}" "$notif_active" "$teams_badge" \
      > "${cache_file}.tmp" && mv "${cache_file}.tmp" "$cache_file") &
    disown $!
  else
    # First run: block until generated
    local icon_b64
    icon_b64=$("$CONFIG_DIR/render-icon" "$amph_active" "$battery_state" \
                 "$wifi_state" "$audio_state" "${copilot_pct:-0}" "$notif_active" "$teams_badge")
    if [ -n "$icon_b64" ]; then
      echo "$icon_b64" > "$cache_file"
      echo "$icon_b64"
    fi
  fi
}

# --- Main -------------------------------------------------------------------

amph_running=false
amph_active=false
if pgrep -x -u "$(id -u)" Amphetamine >/dev/null; then
  amph_running=true
  is_amphetamine_active && amph_active=true
fi

battery_state=$(get_battery_state)
wifi_state=$(get_wifi_state)
audio_state=$(get_audio_state)
get_copilot_data
copilot_pct=$(tr -d '[:space:]' < "$COPILOT_PCT_CACHE" 2>/dev/null)
copilot_stats_active=false
[ -s "$COPILOT_STATS_CACHE" ] && copilot_stats_active=true

get_notifications
notif_active=false
[ -n "$NOTIF_HOST" ] && [ -s "$NOTIF_CACHE" ] && notif_active=true

teams_state=$(get_teams_state)
IFS=$'\t' read -r teams_availability teams_unread <<< "$teams_state"
# Teams icon state: none | away (amber badge) | unread (bubble icon) | awayunread (both).
teams_badge=none
case "$teams_availability" in
  ""|Available|AvailableIdle) ;;
  *) teams_badge=away ;;
esac
if [ "${teams_unread:-0}" -gt 0 ]; then
  if [ "$teams_badge" = away ]; then teams_badge=awayunread; else teams_badge=unread; fi
fi

hide_all=false
[ -f "$HIDE_FLAG" ] && hide_all=true
if $hide_all; then
  # Only the battery survives (render-icon shows it regardless when nothing else is showing).
  icon_b64=$(get_icon false "$battery_state" connected none "" false none)
else
  icon_b64=$(get_icon "$amph_active" "$battery_state" "$wifi_state" "$audio_state" "$copilot_pct" "$notif_active" "$teams_badge")
fi
echo "| image=$icon_b64"

echo "---"

# Battery status
pmout=$(pmset -g batt 2>/dev/null)
battery_percent=$(echo "$pmout" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
battery_remaining=$(echo "$pmout" | grep -Eo '[0-9]+:[0-9]+ remaining' | head -1)
if echo "$pmout" | grep -q "'Battery Power'"; then
  if [ -n "$battery_remaining" ]; then
    echo "Battery: $battery_percent% ($battery_remaining) | refresh=true"
  else
    echo "Battery: $battery_percent% | refresh=true"
  fi
else
  echo "Battery: $battery_percent% (charging) | refresh=true"
fi

echo "---"

# GitHub
if $notif_active; then
  echo "GitHub ($(wc -l < "$NOTIF_CACHE" | tr -d ' ') unread)"
  echo "--Inbox | href=https://$NOTIF_HOST/notifications"
  while IFS=$'\t' read -r title repo url; do
    [ -n "$title" ] || continue
    title=${title//|/¦}
    if [ -n "$url" ]; then
      echo "--${repo##*/}: ${title:0:60} | href=$url"
    else
      echo "--${repo##*/}: ${title:0:60} | href=https://$NOTIF_HOST/notifications"
    fi
  done < "$NOTIF_CACHE"
  echo "-- ---"
  echo "--Clear all | bash='$0' param1=run param2=ghclear param3=$NOTIF_HOST terminal=false refresh=true"
  echo "---"
fi

# Teams info row
if [ -n "$teams_availability" ]; then
  status=$(echo "$teams_availability" | sed -E 's/([a-z])([A-Z])/\1 \2/g')
  if [ "$status" = "Available" ]; then
    if [ "$teams_unread" -gt "0" ]; then
      echo "Teams ($teams_unread unread) | bash='$0' param1=run param2=teams terminal=false"
    fi
  else
    if [ "$teams_unread" -gt "0" ]; then
      echo "Teams ($teams_unread unread) - $status | bash='$0' param1=run param2=teams terminal=false"
    else
      echo "Teams - $status | bash='$0' param1=run param2=teams terminal=false"
    fi
  fi
fi

# Copilot AIC
if $copilot_stats_active; then
  echo "Copilot"
  while IFS= read -r line; do
    if [ "$line" = "---" ]; then echo "-----"
    elif [ -n "$line" ]; then echo "--$line | refresh=true"
    fi
  done < "$COPILOT_STATS_CACHE"
fi

echo "---"

# Lock screen
echo "Lock screen | bash='$0' param1=run param2=lock terminal=false"

# Sound
muted=$(osascript -e "output muted of (get volume settings)")
if [ "$muted" = "true" ]; then
  echo "Sound on | bash='$0' param1=run param2=unmute refresh=true"
else
  echo "Sound on ✓ | bash='$0' param1=run param2=mute refresh=true"
fi

# Keep awake
if $amph_running; then
  label="Keep awake"
  $amph_active && label="Keep awake ✓"
  echo "$label | bash='$0' param1=run param2=awake terminal=false refresh=true"
fi

# Mobile hotspot
wifi_label="Mobile hotspot"
wifi_action="param2=wifi param3=VIRU2"
if [ "$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')" = "172.20.10.1" ]; then
  wifi_label="Mobile hotspot ✓"
  wifi_action="param2=wifi-disconnect"
fi
echo "$wifi_label | bash='$0' param1=run $wifi_action terminal=false refresh=true"

# Low power mode
if pmset -g | grep -Eq 'lowpowermode[[:space:]]+1'; then
  echo "Low power mode ✓ | bash='$0' param1=run param2=lowpower param3=0 terminal=false refresh=true"
else
  echo "Low power mode | bash='$0' param1=run param2=lowpower param3=1 terminal=false refresh=true"
fi

# Hide all toolbar icons except the battery
if $hide_all; then
  echo "No icons ✓ | bash='$0' param1=run param2=hide terminal=false refresh=true"
else
  echo "No icons | bash='$0' param1=run param2=hide terminal=false refresh=true"
fi

echo "---"

# Keymap
echo "Keymap | bash='$0' param1=run param2=keymap terminal=false"

# Headset
if sidetone=$("$SIDETONE" 2>/dev/null); then
  echo "---"
  echo "Headset sidetone"
  for level in 0 16 32 48 64 80 96 112 128; do
    tick=
    (( level == sidetone )) && tick=✓
    echo "--$level $tick| bash='$0' param1=run param2=sidetone param3=$level terminal=false refresh=true"
  done
fi
