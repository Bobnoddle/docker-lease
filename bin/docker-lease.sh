#!/bin/bash
# docker-lease.sh — lease + activity based reaper for local dev stacks.
#
# WHY: agents and CI harnesses run `docker compose up -d` in throwaway
# workspaces. Nothing runs `compose down` on teardown, and scaffolded services
# carry `restart: always`, so stacks survive even a Docker Desktop restart. 40
# orphaned containers once ballooned the Docker VM to 8.6GB on a 16GB host,
# forcing macOS to compress gigabytes and stalling every other app.
#
# OWNERSHIP is derived from the compose working_dir label, never from a pin:
#   $DOCKER_LEASE_AGENT_ROOT/... -> AGENT   subject to idle decay
#   $DOCKER_LEASE_USER_ROOT/...  -> USER    never auto-touched
#   dir deleted                  -> ORPHAN  remove (after grace)
#   dir present, compose gone    -> STRAY   stop (reversible)
#
# AGENT_ROOT is OPT-IN and empty by default: with no agent root the AGENT class
# simply has no members and every non-USER workspace is UNKNOWN (left alone).
# Set it yourself; see README for the documented example.
#
# ACTIVITY is a union: any one signal vetoes a stop. Docker has no native
# "last user interaction" primitive, so we combine heartbeat, resource deltas,
# live TCP sessions and workspace file mtimes.
#
# DECAY:  idle >= STOP_MIN   -> stop + clear restart policy (reversible)
#         idle >= DELETE_HRS -> delete containers (volumes NEVER deleted)
#
# Volumes are reported, never deleted. 17 volumes belonging to live product
# repos were one prune away from destruction; that checkpoint is deliberate.
#
# macOS bash 3.2 compatible: no associative arrays, no process substitution
# in pipelines that would fork state.

# ---------------------------------------------------------------- BRAND ----
# Single source of identity. Keep this block byte-identical across bin/,
# notifier/ and the installers so a rename only happens in one place.
BRAND_PROJECT="docker-lease"
BRAND_OWNER="bobnoddle"
BRAND_NAMESPACE="io.github.${BRAND_OWNER}.docker-lease"
LAUNCHD_LABEL="${BRAND_NAMESPACE}.reaper"
# ---------------------------------------------------------------------------

set -uo pipefail

DOCKER="${DOCKER:-$(command -v docker || echo /usr/local/bin/docker)}"
ROOT="${DOCKER_LEASE_ROOT:-$HOME/.docker-leases}"
LOG="$ROOT/reaper.log"
PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

LEASES="$ROOT/leases"
PINS="$ROOT/pins"
ORPHANS="$ROOT/orphans"
ACTIVITY="$ROOT/activity"
STATS="$ROOT/stats"
STOPPED="$ROOT/stopped"

# Ownership roots. Never default AGENT_ROOT to another tool's private layout:
# that silently claims a directory tree this script does not own.
AGENT_ROOT="${DOCKER_LEASE_AGENT_ROOT:-}"
USER_ROOT="${DOCKER_LEASE_USER_ROOT:-$HOME/Projects}"

STOP_MIN="${DOCKER_STOP_MIN:-30}"
DELETE_HRS="${DOCKER_DELETE_HOURS:-24}"
GRACE_SECS="${DOCKER_REAP_GRACE:-600}"

# Where install writes the launchd agent's ProgramArguments. Resolved so the
# agent works regardless of how the script was invoked, with no hardcoded
# home directory.
SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  /*) ;;
  *) SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;;
esac

mkdir -p "$ROOT" "$LEASES" "$PINS" "$ORPHANS" "$ACTIVITY" "$STATS" "$STOPPED"
touch "$LOG"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }
[ "$(wc -c <"$LOG")" -gt 524288 ] && tail -n 2000 "$LOG" >"$LOG.t" 2>/dev/null && mv "$LOG.t" "$LOG"

# notify: the optional notifier .app attempts the shipped-icon banner; the
# osascript fallback (generic icon) runs if the helper exits non-zero. Neither
# exit status guarantees presentation; failures are logged. The message is
# passed as argv, never interpolated into AppleScript source.
NOTIFY_BIN="${DOCKER_LEASE_NOTIFY_BIN:-$HOME/.local/bin/docker-lease-notifier.app/Contents/MacOS/docker-lease-notify}"
notify() {
  if [ -x "$NOTIFY_BIN" ] && "$NOTIFY_BIN" "$1" >/dev/null 2>&1; then
    return 0
  fi
  log "WARN notification helper failed; attempting osascript fallback"
  if /usr/bin/osascript - "$1" <<'APPLESCRIPT'
on run argv
  display notification (item 1 of argv) with title "docker reaper"
end run
APPLESCRIPT
  then
    return 0
  fi
  log "ERROR notification helper and osascript fallback failed"
  printf '%s\n' 'docker reaper: both notification paths failed' >&2
  return 1
}

docker_ok() { "$DOCKER" info >/dev/null 2>&1; }

compose_in() {
  local d="$1" f
  [ -d "$d" ] || return 1
  for f in "$d"/docker-compose*.yml; do [ -f "$f" ] && return 0; done
  return 1
}

# AGENT | USER | STRAY | ORPHAN | UNKNOWN
classify() {
  local wdir="$1"
  [ -z "$wdir" ] && { echo UNKNOWN; return; }
  [ ! -d "$wdir" ] && { echo ORPHAN; return; }
  compose_in "$wdir" || { echo STRAY; return; }
  # Guard: with AGENT_ROOT empty, "$AGENT_ROOT"/* degenerates to /* and would
  # claim EVERY workspace as AGENT. Empty means "no agent root configured".
  if [ -n "$AGENT_ROOT" ]; then
    case "$wdir" in
      "$AGENT_ROOT"/*) echo AGENT; return ;;
    esac
  fi
  case "$wdir" in
    "$USER_ROOT"/*) echo USER ;;
    *)              echo UNKNOWN ;;
  esac
}

# project \t workdir \t names(csv) \t running(csv) \t published_ports(csv)
enumerate() {
  "$DOCKER" ps -a --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Names}}|{{.State}}|{{.Ports}}' 2>/dev/null \
  | awk -F'|' '
      $1=="" { next }
      { if (!($1 in s)) { s[$1]=1; dir[$1]=$2; nm[$1]=""; rn[$1]=""; pt[$1]="" }
        nm[$1] = nm[$1]=="" ? $3 : nm[$1] "," $3
        if ($4=="running") rn[$1] = rn[$1]=="" ? $3 : rn[$1] "," $3
        if ($5 != "")  pt[$1] = pt[$1]=="" ? $5 : pt[$1] " ; " $5 }
      END { for (p in s) printf "%s\t%s\t%s\t%s\t%s\n", p, dir[p], nm[p], rn[p], pt[p] }' \
  | sort
}

# Every established TCP local port, gathered once per pass.
connected_ports() {
  lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null \
    | awk 'NR>1 { split($9,a,":"); print a[length(a)] }' | sort -u
}

# "1.48kB / 126B" -> bytes. awk, not bash arithmetic: bash 3.2 is integer-only.
net_bytes() {
  printf '%s' "$1" | awk '{
    total = 0; n = split($0, parts, "/")
    for (i = 1; i <= n; i++) {
      v = parts[i]; gsub(/^[ \t]+|[ \t]+$/, "", v)
      if      (v ~ /GB$/) { sub(/GB$/, "", v); m = 1073741824 }
      else if (v ~ /MB$/) { sub(/MB$/, "", v); m = 1048576 }
      else if (v ~ /kB$/) { sub(/kB$/, "", v); m = 1024 }
      else if (v ~ /B$/)  { sub(/B$/,  "", v); m = 1 }
      else next
      total += v * m
    }
    printf "%d\n", total
  }'
}

# Returns "active|quiet" plus a reason list
activity_check() {
  local proj="$1" wdir="$2" ports="$3"
  local reasons="" now; now=$(date +%s)

  # A lease only counts as activity while it is FRESH. An old lease file must
  # not pin a stack open forever.
  if [ -f "$LEASES/$proj" ]; then
    local lm; lm=$(stat -f %m "$LEASES/$proj" 2>/dev/null || echo 0)
    [ $(( now - lm )) -lt $(( STOP_MIN * 60 )) ] && reasons="$reasons heartbeat"
  fi
  [ -n "$(find "$wdir" -type f -mmin "-$STOP_MIN" -print -quit 2>/dev/null)" ] \
    && reasons="$reasons files"

  # Resource delta vs previous pass. BYTES ONLY: CPU jitters constantly on an
  # idle stack and would make every pass look active. A real workload moves
  # bytes. Threshold guards against counter noise.
  local sig="" name net bytes prev pbytes
  for name in $(echo "${4:-}" | tr ',' ' '); do
    [ -z "$name" ] && continue
    net=$("$DOCKER" stats --no-stream --format '{{.NetIO}}' "$name" 2>/dev/null)
    bytes=$(net_bytes "$net")
    prev=$(cat "$STATS/$proj.bytes" 2>/dev/null || echo "")
    if [ -n "$prev" ] && [ $(( bytes - prev )) -gt 1024 ]; then
      reasons="$reasons delta"
    fi
    printf '%s\n' "$bytes" > "$STATS/$proj.bytes.tmp" 2>/dev/null
  done
  [ -f "$STATS/$proj.bytes.tmp" ] && mv "$STATS/$proj.bytes.tmp" "$STATS/$proj.bytes"

  # live TCP sessions on published ports
  if [ -n "$ports" ] && [ -n "${CONN_PORTS:-}" ]; then
    for p in $(echo "$ports" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+->' | cut -d: -f2 | tr -d '>'); do
      echo "$CONN_PORTS" | grep -qx "$p" && reasons="$reasons session"
    done
  fi

  if [ -n "$reasons" ]; then
    echo "$now" > "$ACTIVITY/$proj" 2>/dev/null
    echo "active ${reasons# }"
  else
    echo quiet
  fi
}

human() { printf '%dh%02dm' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )); }

cmd_status() {
  docker_ok || { echo "docker daemon not reachable"; return 1; }
  local now; now=$(date +%s)
  printf '%-20s %-8s %-7s %-4s %-8s %-8s %s\n' PROJECT OWNER RUN PIN IDLE SINCE STATE
  printf '%s\n' "----------------------------------------------------------------------------"
  enumerate | while IFS=$'\t' read -r proj wdir names running ports; do
    local owner cls pin idle since state
    cls=$(classify "$wdir"); owner=$cls
    [ "$cls" = "UNKNOWN" ] && owner="-"
    pin=$([ -f "$PINS/$proj" ] && echo yes || echo no)
    if [ -f "$ACTIVITY/$proj" ]; then
      idle=$(( now - $(cat "$ACTIVITY/$proj" 2>/dev/null || echo "$now") ))
      since=$([ -f "$STOPPED/$proj" ] && echo stopped || echo running )
    else
      idle=-1; since="-"
    fi
    if [ "$pin" = "yes" ]; then state="PINNED"
    elif [ "$cls" = "USER" ]; then state="user (never reaped)"
    elif [ -n "$running" ]; then state="up"
    else state="down"
    fi
    local idl="-" ; [ "$idle" -ge 0 ] 2>/dev/null && idl=$(human "$idle")
    printf '%-20s %-8s %-7s %-4s %-8s %-8s %s\n' \
      "$proj" "$owner" "$([ -n "$running" ] && echo yes || echo no)" "$pin" "$idl" "$since" "$state"
  done
  echo
  echo "stop after ${STOP_MIN}m idle | delete containers after ${DELETE_HRS}h | volumes never deleted"
  echo "config: DOCKER_STOP_MIN  DOCKER_DELETE_HOURS  DOCKER_REAP_GRACE"
}

cmd_reap() {
  local dry=0
  for a in "$@"; do [ "$a" = "--dry-run" ] && dry=1; done
  docker_ok || { log "reap skipped: daemon unreachable"; return 0; }

  local now; now=$(date +%s)
  local acted=0
  CONN_PORTS=$(connected_ports)

  enumerate | while IFS=$'\t' read -r proj wdir names running ports; do
    local cls act="" why=""

    # PINNED short-circuits everything.
    if [ -f "$PINS/$proj" ]; then
      log "skip $proj: pinned"
      continue
    fi

    cls=$(classify "$wdir")

    case "$cls" in
      ORPHAN)
        # require persistence across two passes so a workspace being created
        # right now is never torn down under its agent
        local stamp="$ORPHANS/$proj" first
        if [ ! -f "$stamp" ]; then
          echo "$now" > "$stamp"; why="deferred (first sighting)"
        else
          first=$(stat -f %m "$stamp" 2>/dev/null || echo "$now")
          if [ $(( now - first )) -lt "$GRACE_SECS" ]; then
            why="deferred (grace)"
          else
            act="remove"; rm -f "$stamp"
          fi
        fi
        ;;

      STRAY)
        # compose file gone => the stack can never be started by compose again.
        # Stop immediately (reversible), then delete once it has sat idle long
        # enough. Without this they accumulate forever, which is the exact slow
        # leak this script exists to prevent.
        if [ -n "$running" ]; then
          act="stop"; why="compose file gone"
        else
          "$DOCKER" update --restart=no $(echo "$names" | tr ',' ' ') >/dev/null 2>&1
          local sst; sst=$(cat "$STOPPED/$proj" 2>/dev/null || echo "")
          if [ -z "$sst" ]; then
            echo "$now" > "$STOPPED/$proj"; why="down, restart policy cleared"
          elif [ $(( now - sst )) -ge $(( DELETE_HRS * 3600 )) ]; then
            act="remove"; why="unreachable $(human $(( now - sst )))"; rm -f "$STOPPED/$proj"
          else
            why="down $(human $(( now - sst )))"
          fi
        fi
        ;;

      USER)
        rm -f "$ACTIVITY/$proj" "$STATS/$proj" 2>/dev/null
        why="user-owned, never reaped"
        ;;

      UNKNOWN)
        why="unclassified working_dir, left alone"
        ;;

      AGENT)
        local act_state
        act_state=$(activity_check "$proj" "$wdir" "$ports" "$names")
        case "$act_state" in
          active*) : ;;
          quiet*)
            local idle=0
            [ -f "$ACTIVITY/$proj" ] && idle=$(( now - $(cat "$ACTIVITY/$proj" 2>/dev/null || echo "$now") ))
            if [ "$idle" -ge $(( DELETE_HRS * 3600 )) ] && [ -n "$running" ]; then
              act="remove"; why="idle $(human "$idle") >= ${DELETE_HRS}h"
            elif [ "$idle" -ge $(( STOP_MIN * 60 )) ] && [ -n "$running" ]; then
              act="stop"; why="idle $(human "$idle")"
            elif [ -z "$running" ] && [ -f "$STOPPED/$proj" ] \
                 && [ $(( now - $(cat "$STOPPED/$proj") )) -ge $(( DELETE_HRS * 3600 )) ]; then
              act="remove"; why="stopped $(human $(( now - $(cat "$STOPPED/$proj") ))) ago"
            else
              why="idle $(human "$idle")"
            fi
            ;;
        esac
        ;;
    esac

    if [ -z "$act" ]; then
      [ -n "$why" ] && log "note $proj ($cls): $why"
      continue
    fi

    if [ "$dry" -eq 1 ]; then
      printf '  [dry-run] %-7s %-20s %s\n' "$cls" "$proj" "$act"
      log "dry-run would $act $proj ($why)"
      continue
    fi

    # Clear restart policy FIRST or the next Docker Desktop start resurrects them.
    "$DOCKER" update --restart=no $(echo "$names" | tr ',' ' ') >/dev/null 2>&1

    if [ "$act" = "remove" ]; then
      "$DOCKER" rm -f $(echo "$names" | tr ',' ' ') >/dev/null 2>&1
      rm -f "$ACTIVITY/$proj" "$STATS/$proj" "$STOPPED/$proj" "$LEASES/$proj" "$ORPHANS/$proj"
      printf '  deleted   %-7s %-20s %s\n' "$cls" "$proj" "$why"
      notify "deleted $proj ($why)"
      log "DELETED $proj ($cls): $why"
    else
      "$DOCKER" stop $(echo "$names" | tr ',' ' ') >/dev/null 2>&1
      [ "$cls" = "AGENT" ] && echo "$now" > "$STOPPED/$proj"
      printf '  stopped   %-7s %-20s %s\n' "$cls" "$proj" "$why"
      notify "stopped $proj ($why) - reversible with: docker start"
      log "STOPPED $proj ($cls): $why"
    fi
    echo 1 > "$ROOT/.acted"
  done

  if [ -f "$ROOT/.acted" ]; then
    rm -f "$ROOT/.acted"
    log "reap pass complete (actions taken)"
    return 1
  fi
  log "reap pass complete (no action)"
  return 0
}

cmd_heartbeat() {
  local p="${1:?usage: docker-lease.sh heartbeat <project>}"
  docker_ok || { echo "docker daemon not reachable" >&2; return 1; }
  date +%s > "$LEASES/$p"; date +%s > "$ACTIVITY/$p"
  rm -f "$STOPPED/$p"
  log "heartbeat $p"
  echo "lease refreshed: $p"
}

cmd_pin() {
  local p="${1:?usage: docker-lease.sh pin <project>}"
  mkdir -p "$PINS"; : > "$PINS/$p"; date +%s > "$ACTIVITY/$p"
  log "pinned $p"; echo "pinned (never reaped): $p"
}

cmd_unpin() {
  local p="${1:?usage: docker-lease.sh unpin <project>}"
  rm -f "$PINS/$p"; log "unpinned $p"; echo "unpinned: $p"
}

cmd_reap_volumes() {
  docker_ok || { echo "docker daemon not reachable"; return 1; }
  local n
  n=$("$DOCKER" volume ls -q --filter dangling=true 2>/dev/null | wc -l | tr -d ' ')
  echo "dangling volumes: $n  (NOT deleted - prune manually if you accept the loss)"
  "$DOCKER" system df 2>/dev/null | grep -i volumes | sed 's/^/  /'
}

cmd_install() {
  mkdir -p "$HOME/Library/LaunchAgents"
  cat >"$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_PATH</string>
    <string>reap</string>
  </array>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$ROOT/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$ROOT/launchd.err.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLISTEOF
  # `load`/`unload` still work on macOS 13+ but are deprecated; `bootstrap`/
  # `bootout` are the supported spelling in the modern per-user domain. Try the
  # modern form first and fall back so this keeps working in odd sessions
  # (ssh without a GUI session, older hosts).
  launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 \
    || launchctl unload "$PLIST" >/dev/null 2>&1
  launchctl bootstrap "gui/$UID" "$PLIST" >/dev/null 2>&1 \
    || launchctl load "$PLIST"
  log "installed launchd agent ($LAUNCHD_LABEL, every 600s)"
  echo "installed: $PLIST"
}

cmd_uninstall() {
  launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 \
    || launchctl unload "$PLIST" >/dev/null 2>&1
  rm -f "$PLIST"
  log "uninstalled launchd agent ($LAUNCHD_LABEL)"
  echo "removed: $PLIST"
}

case "${1:-status}" in
  heartbeat|hb) shift; cmd_heartbeat "$@" ;;
  status|st)     shift; cmd_status "$@" ;;
  reap)         shift; cmd_reap "$@" ;;
  pin)          shift; cmd_pin "$@" ;;
  unpin)        shift; cmd_unpin "$@" ;;
  volumes)      cmd_reap_volumes ;;
  install)      cmd_install ;;
  uninstall)    cmd_uninstall ;;
  *) echo "usage: docker-lease.sh {status|reap [--dry-run]|heartbeat <p>|pin <p>|unpin <p>|volumes|install|uninstall}"; exit 1 ;;
esac
