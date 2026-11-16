#!/bin/bash
# uninstall.sh: remove docker-lease from the current user.
#
# Removes the launchd agent, the script, the notification helper and the env
# block install.sh added to your shell profile. Leaves Docker alone: no
# container is stopped or removed, and stacks that were already stopped stay
# stopped (that was a reversible action taken earlier, not part of removal).
#
# Usage:
#   ./uninstall.sh                 # keep state in ~/.docker-leases
#   ./uninstall.sh --purge         # also delete the state directory
#   ./uninstall.sh --bin-dir ~/bin
#   ./uninstall.sh --profile ~/.zshrc
#
# State is kept by default because it records which stacks were stopped and
# when; deleting it is safe but loses that history.

# ---------------------------------------------------------------- BRAND ----
BRAND_PROJECT="docker-lease"
BRAND_OWNER="bobnoddle"
BRAND_NAMESPACE="io.github.${BRAND_OWNER}.docker-lease"
LAUNCHD_LABEL="${BRAND_NAMESPACE}.reaper"
NOTIFIER_BUNDLE_ID="${BRAND_NAMESPACE}-notifier"
# ---------------------------------------------------------------------------

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
PROFILE=""
PURGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir) BIN_DIR="${2:?--bin-dir needs a directory}"; shift 2 ;;
    --profile) PROFILE="${2:?--profile needs a file}"; shift 2 ;;
    --purge)   PURGE=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "uninstall.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
STATE="${DOCKER_LEASE_ROOT:-$HOME/.docker-leases}"

# --- 1. launchd agent ------------------------------------------------------
if [ -x "$BIN_DIR/docker-lease.sh" ] && [ -f "$PLIST" ]; then
  DOCKER_LEASE_ROOT="$STATE" bash "$BIN_DIR/docker-lease.sh" uninstall || true
elif [ -f "$PLIST" ]; then
  launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || launchctl unload "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  say "removed launchd agent: $PLIST"
else
  say "no launchd agent installed at $PLIST"
fi

# --- 2. script + notifier --------------------------------------------------
if [ -f "$BIN_DIR/docker-lease.sh" ]; then
  rm -f "$BIN_DIR/docker-lease.sh"
  say "removed script: $BIN_DIR/docker-lease.sh"
fi
if [ -d "$BIN_DIR/docker-lease-notifier.app" ]; then
  rm -rf "$BIN_DIR/docker-lease-notifier.app"
  say "removed notifier: $BIN_DIR/docker-lease-notifier.app"
fi

# --- 3. shell profile env block -------------------------------------------
if [ -z "$PROFILE" ]; then
  for candidate in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$candidate" ] && grep -q "^# >>> ${BRAND_PROJECT} >>>$" "$candidate" 2>/dev/null; then
      PROFILE="$candidate"
      break
    fi
  done
fi

if [ -n "$PROFILE" ] && [ -f "$PROFILE" ] && grep -q "^# >>> ${BRAND_PROJECT} >>>$" "$PROFILE"; then
  tmp="$PROFILE.${BRAND_PROJECT}.tmp.$$"
  awk -v b="# >>> ${BRAND_PROJECT} >>>" -v e="# <<< ${BRAND_PROJECT} <<<" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' "$PROFILE" >"$tmp"
  mv "$tmp" "$PROFILE"
  say "removed env block from: $PROFILE"
elif [ -n "$PROFILE" ]; then
  say "no docker-lease env block found in: $PROFILE"
fi

# --- 4. state --------------------------------------------------------------
if [ "$PURGE" -eq 1 ]; then
  if [ -d "$STATE" ]; then
    rm -rf "$STATE"
    say "purged state: $STATE"
  fi
else
  say "kept state: $STATE (use --purge to delete)"
fi

say ""
say "Removed. Notification permission for $NOTIFIER_BUNDLE_ID stays in System"
say "Settings > Notifications; clear it there if you also want that gone."
