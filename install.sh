#!/bin/bash
# install.sh — install docker-lease for the current user.
#
# What it does, in order:
#   1. copies bin/docker-lease.sh into the bin directory
#   2. builds the optional notification helper into <bin>/docker-lease-notifier.app
#   3. appends an env block to your shell profile (shown, never silent)
#   4. runs `docker-lease.sh install`, which writes and loads the launchd agent
#
# It never touches Docker itself: no containers are stopped, started or removed
# by this script.
#
# Usage:
#   ./install.sh                          # ~/.local/bin + zsh profile
#   ./install.sh --bin-dir ~/bin
#   ./install.sh --no-notifier            # osascript fallback only
#   ./install.sh --no-profile             # do not edit any shell profile
#   ./install.sh --profile ~/.config/fish/conf.d/x.fish   # you own the syntax
#
# Re-running is safe: the profile block is replaced, not appended twice.

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
PROFILE_MODE="auto"     # auto | file | none
WANT_NOTIFIER=1

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir)  BIN_DIR="${2:?--bin-dir needs a directory}"; shift 2 ;;
    --profile)  PROFILE="${2:?--profile needs a file}"; PROFILE_MODE="file"; shift 2 ;;
    --no-profile) PROFILE_MODE="none"; shift ;;
    --no-notifier) WANT_NOTIFIER=0; shift ;;
    -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$HERE/bin/docker-lease.sh" ] || die "bin/docker-lease.sh missing; run install.sh from the repo"
command -v docker >/dev/null 2>&1 || warn "docker not on PATH; the agent will run but skip every pass until it is"

# --- 1. script -------------------------------------------------------------
mkdir -p "$BIN_DIR"
install -m 0755 "$HERE/bin/docker-lease.sh" "$BIN_DIR/docker-lease.sh"
say "installed script: $BIN_DIR/docker-lease.sh"

# --- 2. notifier (optional) ------------------------------------------------
if [ "$WANT_NOTIFIER" -eq 1 ]; then
  if command -v swiftc >/dev/null 2>&1; then
    OUT="$BIN_DIR" ICON_SRC="$HERE/assets/icon/master.png" \
      NOTIFIER_BUNDLE_ID="$NOTIFIER_BUNDLE_ID" \
      bash "$HERE/notifier/build.sh" || warn "notifier build failed; notifications will use osascript"
  else
    warn "swiftc not found; skipping the notifier (osascript fallback still works)"
  fi
else
  say "skipping notifier (--no-notifier): osascript fallback only"
fi

# --- 3. profile env block --------------------------------------------------
PROFILE_BEGIN="# >>> ${BRAND_PROJECT} >>>"
PROFILE_END="# <<< ${BRAND_PROJECT} <<<"

if [ "$PROFILE_MODE" = "auto" ]; then
  case "${SHELL:-}" in
    */zsh)  PROFILE="$HOME/.zshrc" ;;
    */bash) if [ -f "$HOME/.bash_profile" ]; then PROFILE="$HOME/.bash_profile"; else PROFILE="$HOME/.bashrc"; fi ;;
    *)      PROFILE="$HOME/.profile" ;;
  esac
fi

if [ "$PROFILE_MODE" = "none" ]; then
  say "leaving shell profiles alone (--no-profile)"
else
  touch "$PROFILE"
  # The block body is kept literal (quoted heredoc): ${VAR:-default} must be
  # evaluated when the user's shell starts, not now.
  block="$(mktemp "${TMPDIR:-/private/tmp}/docker-lease-profile.XXXXXX")"
  cat >"$block" <<'PROFILEEOF'
# >>> docker-lease >>>
# Managed by docker-lease install.sh. Delete this block to revert.
# Where lease/heartbeat state lives:
export DOCKER_LEASE_ROOT="${DOCKER_LEASE_ROOT:-$HOME/.docker-leases}"
# Stacks whose compose working_dir sits under this tree are USER-owned and never
# auto-reaped:
export DOCKER_LEASE_USER_ROOT="${DOCKER_LEASE_USER_ROOT:-$HOME/Projects}"
# Agent/CI workspace tree. OPT-IN: uncomment and point it at YOUR own tree, or
# the AGENT class stays empty and those stacks are left alone as UNKNOWN.
# export DOCKER_LEASE_AGENT_ROOT="$HOME/path/to/agent/worktrees"
# Override the docker binary if it is not on PATH:
# export DOCKER="/Applications/Docker.app/Contents/Resources/bin/docker"
# <<< docker-lease <<<
PROFILEEOF

  # Drop any previous block so re-installs do not stack up.
  tmp="$PROFILE.${BRAND_PROJECT}.tmp.$$"
  awk -v b="$PROFILE_BEGIN" -v e="$PROFILE_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' "$PROFILE" >"$tmp"
  cat "$block" >>"$tmp"
  mv "$tmp" "$PROFILE"
  say "updated shell profile: $PROFILE"
  say "  env block written:"
  sed 's/^/    /' "$block"
  rm -f "$block"
fi

# --- 4. launchd agent ------------------------------------------------------
say ""
DOCKER_LEASE_ROOT="${DOCKER_LEASE_ROOT:-$HOME/.docker-leases}" \
  bash "$BIN_DIR/docker-lease.sh" install

say ""
say "done. The agent reaps every 10 minutes (launchd label: $LAUNCHD_LABEL)."
say "Try it read-only first:"
say "  $BIN_DIR/docker-lease.sh status"
say "  $BIN_DIR/docker-lease.sh reap --dry-run"
say "Open a new shell (or 'source $PROFILE') so the exported env applies."
