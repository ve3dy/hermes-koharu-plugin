#!/usr/bin/env bash
# Remove the Hermes Koharu plugin and its koharu-batch runner (counterpart of
# install.sh). Koharu's own config and model cache are shared with the Koharu
# desktop app and are never deleted.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh [--dry-run] [--purge] [--help]

Disables the koharu plugin in Hermes, removes its Hermes settings, the plugin
directory and the koharu-batch runner. Exports are kept.

Options:
  --dry-run   Print every action without changing anything.
  --purge     Also remove KOHARU_HOME entirely (Koharu source + build cache).
  -h, --help  Show this help.

Environment: HERMES_HOME, HERMES_BIN, KOHARU_HOME, RESTART_GATEWAY [1]
(same meaning as in install.sh).

Never touched (shared with the Koharu desktop app): ~/.koharu and the Koharu
model cache (macOS ~/Library/Caches/Koharu, Linux ~/.cache/koharu).
EOF
}

DRY_RUN=0
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown argument: %s (see --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME
RESTART_GATEWAY="${RESTART_GATEWAY:-1}"
PLUGIN_DEST="$HERMES_HOME/plugins/koharu"
OS="$(uname -s)"

case "$OS" in
  Darwin)
    KOHARU_HOME="${KOHARU_HOME:-$HOME/Library/Application Support/hermes-koharu}"
    KOHARU_CACHE="$HOME/Library/Caches/Koharu"
    ;;
  Linux)
    KOHARU_HOME="${KOHARU_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/hermes-koharu}"
    KOHARU_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/koharu"
    ;;
  *) printf 'error: unsupported OS: %s (on Windows run scripts\\uninstall.ps1 in PowerShell)\n' "$OS" >&2; exit 1 ;;
esac

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

quote_cmd() {
  local out="" a
  for a in "$@"; do out="$out $(printf '%q' "$a")"; done
  printf '%s' "${out# }"
}

# Run (or print under --dry-run). A failure is only reported.
run_ok() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] %s\n' "$(quote_cmd "$@")"
  else
    "$@" || warn "ignored failure: $(quote_cmd "$@")"
  fi
}

if [ -z "${HERMES_BIN:-}" ]; then
  HERMES_BIN="$(type -P hermes || true)"
  if [ -z "$HERMES_BIN" ] && [ -x "$HOME/.local/bin/hermes" ]; then
    HERMES_BIN="$HOME/.local/bin/hermes"
  fi
fi

hermes_ok() {
  if [ -z "$HERMES_BIN" ]; then
    warn "hermes CLI not found (set HERMES_BIN), skipped: hermes $*"
  else
    run_ok "$HERMES_BIN" "$@" </dev/null
  fi
}

[ "$DRY_RUN" = 0 ] || log "Dry run: nothing will be changed"

log "Removing the koharu plugin from Hermes (HERMES_HOME=$HERMES_HOME)"
hermes_ok plugins disable koharu
hermes_ok config unset plugins.entries.koharu
run_ok rm -rf "$PLUGIN_DEST"

if [ "$PURGE" = 1 ]; then
  log "Purging $KOHARU_HOME (runner, Koharu source and build cache)"
  run_ok rm -rf "$KOHARU_HOME"
else
  log "Removing the runner $KOHARU_HOME/bin"
  run_ok rm -rf "$KOHARU_HOME/bin"
fi

if [ "$RESTART_GATEWAY" = 1 ]; then
  log "Restarting the Hermes gateway"
  hermes_ok gateway restart
else
  log "Gateway not restarted (RESTART_GATEWAY=0). Run: ${HERMES_BIN:-hermes} gateway restart"
fi

cat <<EOF

Koharu plugin and runner removed.
  Kept (shared with the Koharu desktop app):
    $HOME/.koharu
    $KOHARU_CACHE
EOF
[ "$PURGE" = 1 ] || echo "  Kept $KOHARU_HOME/src (Koharu source + build cache, remove with --purge)"
