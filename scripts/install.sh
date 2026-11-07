#!/usr/bin/env bash
# Install the Hermes Koharu plugin and build its headless runner, koharu-batch,
# from pinned Koharu source (Koharu releases ship no headless mode).
#
#   1. Clone Koharu at a pinned tag and verify the commit.
#   2. Copy runner/ into the Koharu workspace as crates/koharu-batch and build
#      it with cargo (skipped when the source stamp is unchanged).
#   3. Copy the plugin into Hermes and configure it through the Hermes CLI.
#
# Hermes config is changed only through the Hermes CLI. This script never
# rewrites config.yaml.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [--dry-run] [--help]

Builds the koharu-batch runner from pinned Koharu source and installs the
Koharu plugin into Hermes. Idempotent: reruns reuse the source checkout and
skip the build when nothing changed.

Needs: git, curl, rsync and a C toolchain with clang.
  macOS: Xcode Command Line Tools
  Linux: cc, c++, clang, pkg-config and the fontconfig + OpenSSL dev packages
         (Debian/Ubuntu: build-essential clang pkg-config libfontconfig1-dev libssl-dev)
Rust is installed with rustup (~/.cargo) when cargo is missing.

Options:
  --dry-run   Print every action without changing anything.
  -h, --help  Show this help.

Environment (defaults in brackets):
  HERMES_HOME        Hermes home                          [~/.hermes]
  HERMES_BIN         hermes CLI                           [hermes on PATH]
  KOHARU_HOME        Source checkout + runner binary
                     macOS [~/Library/Application Support/hermes-koharu]
                     Linux [${XDG_DATA_HOME:-~/.local/share}/hermes-koharu]
  KOHARU_EXPORT_DIR  Where translated pages are written   [~/Koharu/exports]
  RESTART_GATEWAY    1 = run `hermes gateway restart`     [1]
EOF
}

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown argument: %s (see --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

KOHARU_REPO="https://github.com/koharu-rs/koharu.git"
# The runner uses Koharu's internal crates, which can change between releases.
# The installer builds the latest release. If that fails to build, it falls back
# to this last release known to work.
KNOWN_GOOD_TAG="0.83.5"
KNOWN_GOOD_COMMIT="52bb4f55e2266f72c1523562a583c827ec191ceb"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME
KOHARU_EXPORT_DIR="${KOHARU_EXPORT_DIR:-$HOME/Koharu/exports}"
RESTART_GATEWAY="${RESTART_GATEWAY:-1}"
PLUGIN_SRC="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DEST="$HERMES_HOME/plugins/koharu"
SETTINGS_KEY="plugins.entries.koharu.settings"
KOHARU_CONFIG="$HOME/.koharu/config.toml"
OS="$(uname -s)"

case "$OS" in
  Darwin) KOHARU_HOME="${KOHARU_HOME:-$HOME/Library/Application Support/hermes-koharu}" ;;
  Linux) KOHARU_HOME="${KOHARU_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/hermes-koharu}" ;;
  *) printf 'error: unsupported OS: %s (on Windows run scripts\\install.ps1 in PowerShell)\n' "$OS" >&2; exit 1 ;;
esac
SRC_ROOT="$KOHARU_HOME/src"
BIN_DIR="$KOHARU_HOME/bin"
RUNNER="$BIN_DIR/koharu-batch"
STAMP_FILE="$BIN_DIR/.koharu-batch.stamp"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

quote_cmd() {
  local out="" a
  for a in "$@"; do out="$out $(printf '%q' "$a")"; done
  printf '%s' "${out# }"
}

# Run a command, or only print it under --dry-run.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] %s\n' "$(quote_cmd "$@")"
  else
    "$@"
  fi
}

hermes() { run "$HERMES_BIN" "$@" </dev/null; }

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi
}

# Stamp = Koharu commit + hash of every runner source file (name and content).
runner_stamp() {
  local f
  printf '%s\n' "$KOHARU_COMMIT"
  (
    cd "$PLUGIN_SRC/runner"
    find Cargo.toml src -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"
      cat "$f"
    done
  ) | sha256 | awk '{print $1}'
}

# ---------------------------------------------------------------- validation
case "$RESTART_GATEWAY" in 0|1) ;; *) die "RESTART_GATEWAY must be 0 or 1" ;; esac
[ -f "$PLUGIN_SRC/plugin.yaml" ] || die "plugin.yaml not found in $PLUGIN_SRC"
[ -f "$PLUGIN_SRC/runner/Cargo.toml" ] || die "runner/Cargo.toml not found in $PLUGIN_SRC"
for tool in git curl rsync; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
case "$OS" in
  Darwin)
    xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools are missing. Run: xcode-select --install (then rerun this script)"
    command -v clang >/dev/null 2>&1 || die "clang is required (part of the Xcode Command Line Tools)"
    ;;
  Linux)
    # Koharu links against system fontconfig and OpenSSL and needs clang for bindgen.
    missing=""
    for tool in cc c++ clang pkg-config; do
      command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if command -v pkg-config >/dev/null 2>&1; then
      for lib in fontconfig openssl; do
        pkg-config --exists "$lib" || missing="$missing $lib(dev)"
      done
    fi
    if [ -n "$missing" ]; then
      printf 'error: missing build dependencies:%s\n' "$missing" >&2
      cat >&2 <<'EOF'
Install them, then rerun this script:
  Debian/Ubuntu: sudo apt install build-essential clang pkg-config libfontconfig1-dev libssl-dev
  Fedora:        sudo dnf install gcc gcc-c++ clang pkgconf-pkg-config fontconfig-devel openssl-devel
  Arch:          sudo pacman -S base-devel clang pkgconf fontconfig openssl
EOF
      exit 1
    fi
    ;;
esac

case "$KOHARU_EXPORT_DIR" in
  \~/*) KOHARU_EXPORT_DIR="$HOME/${KOHARU_EXPORT_DIR#\~/}" ;;
esac

if [ -z "${HERMES_BIN:-}" ]; then
  HERMES_BIN="$(type -P hermes || true)"
  if [ -z "$HERMES_BIN" ] && [ -x "$HOME/.local/bin/hermes" ]; then
    HERMES_BIN="$HOME/.local/bin/hermes"
  fi
fi
[ -n "$HERMES_BIN" ] || [ "$DRY_RUN" = 1 ] || die "hermes CLI not found, set HERMES_BIN"
HERMES_BIN="${HERMES_BIN:-hermes}"

# ---------------------------------------------------------------------- Rust
CARGO_BIN_DIR="${CARGO_HOME:-$HOME/.cargo}/bin"
ensure_rust() {
  if command -v cargo >/dev/null 2>&1; then
    CARGO="$(command -v cargo)"
  elif [ -x "$CARGO_BIN_DIR/cargo" ]; then
    CARGO="$CARGO_BIN_DIR/cargo"
  else
    log "Installing Rust with rustup (minimal profile, PATH not modified)"
    if [ "$DRY_RUN" = 1 ]; then
      printf '[dry-run] curl https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path\n'
    else
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
        sh -s -- -y --profile minimal --no-modify-path
    fi
    CARGO="$CARGO_BIN_DIR/cargo"
  fi
  # rustup proxies and build scripts expect the toolchain dir on PATH.
  PATH="$(dirname "$CARGO"):$PATH"
  export PATH
  log "Using cargo: $CARGO"
}

# -------------------------------------------------------------------- source
# Sets KOHARU_TAG/KOHARU_COMMIT to the newest x.y.z release tag upstream.
# Annotated tags list a `^{}` line with the commit, which wins over the tag object.
resolve_latest() {
  local line
  line="$(git ls-remote --tags "$KOHARU_REPO" 2>/dev/null |
    awk -F'refs/tags/' '{tag = $2; sha = substr($1, 1, 40)
      peeled = sub(/\^\{\}$/, "", tag)
      if (tag !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) next
      if (peeled || !(tag in c)) c[tag] = sha}
      END {for (t in c) print t, c[t]}' |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" || true
  if [ -z "$line" ]; then
    warn "could not list Koharu releases, using $KNOWN_GOOD_TAG"
    KOHARU_TAG="$KNOWN_GOOD_TAG"; KOHARU_COMMIT="$KNOWN_GOOD_COMMIT"
    return
  fi
  KOHARU_TAG="${line%% *}"
  KOHARU_COMMIT="$(printf '%s' "${line#* }" | tr -d '[:space:]')"
}

fetch_source() {
  SRC_DIR="$SRC_ROOT/koharu-$KOHARU_TAG"
  if [ -d "$SRC_DIR/.git" ]; then
    log "Reusing Koharu source $SRC_DIR"
  else
    log "Cloning Koharu $KOHARU_TAG into $SRC_DIR"
    run mkdir -p "$SRC_ROOT"
    run rm -rf "$SRC_DIR.part"
    run git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$KOHARU_TAG" "$KOHARU_REPO" "$SRC_DIR.part"
    run mv "$SRC_DIR.part" "$SRC_DIR"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] verify git HEAD == %s\n' "$KOHARU_COMMIT"
  else
    local head
    head="$(git -C "$SRC_DIR" rev-parse HEAD)"
    [ "$head" = "$KOHARU_COMMIT" ] || die "$SRC_DIR is at $head, expected $KOHARU_COMMIT (tag $KOHARU_TAG). Delete it and rerun"
    log "Koharu source verified at $KOHARU_COMMIT"
  fi
  run mkdir -p "$SRC_DIR/crates/koharu-batch"
  run rsync -a --delete "$PLUGIN_SRC/runner/" "$SRC_DIR/crates/koharu-batch/"
}

# --------------------------------------------------------------------- build
# Returns 1 if cargo fails, so the caller can fall back.
build_runner() {
  local stamp
  stamp="$(runner_stamp)"
  if [ -x "$RUNNER" ] && [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$stamp" ]; then
    log "koharu-batch is up to date for Koharu $KOHARU_TAG, build skipped"
    return 0
  fi
  log "Building koharu-batch against Koharu $KOHARU_TAG (first build takes a few minutes)"
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] (cd %q && CARGO_TARGET_DIR=target %q build --release -p koharu-batch)\n' "$SRC_DIR" "$CARGO"
  else
    (cd "$SRC_DIR" && CARGO_TARGET_DIR="$SRC_DIR/target" "$CARGO" build --release -p koharu-batch) || return 1
  fi
  run mkdir -p "$BIN_DIR"
  run cp "$SRC_DIR/target/release/koharu-batch" "$RUNNER.part"
  run mv -f "$RUNNER.part" "$RUNNER"
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] write %s\n' "$STAMP_FILE"
  else
    printf '%s\n' "$stamp" >"$STAMP_FILE"
  fi
}

# Keep only the source tree that was just built (each is ~2 GB with build cache).
prune_sources() {
  local d
  for d in "$SRC_ROOT"/koharu-*; do
    [ -d "$d" ] && [ "$d" != "$SRC_DIR" ] && run rm -rf "$d"
  done
  return 0
}


# -------------------------------------------------------------------- Hermes
install_plugin() {
  log "Copying plugin to $PLUGIN_DEST"
  run mkdir -p "$PLUGIN_DEST"
  run rsync -a --delete \
    --exclude .git --exclude .github --exclude __pycache__ --exclude .pytest_cache \
    --exclude tests --exclude scripts --exclude runner --exclude assets \
    --exclude .DS_Store \
    "$PLUGIN_SRC/" "$PLUGIN_DEST/"

  log "Configuring Hermes via $HERMES_BIN (HERMES_HOME=$HERMES_HOME)"
  hermes plugins enable koharu --no-allow-tool-override
  hermes config set "$SETTINGS_KEY.runner" "$RUNNER"
  hermes config set "$SETTINGS_KEY.export_dir" "$KOHARU_EXPORT_DIR"
  hermes config set "$SETTINGS_KEY.timeout" 3600
  hermes tools enable --platform cli koharu
  hermes tools enable --platform telegram koharu
  run mkdir -p "$KOHARU_EXPORT_DIR"
}

# ---------------------------------------------------------------------- main
[ "$DRY_RUN" = 0 ] || log "Dry run: nothing will be changed"
log "Koharu runner on $OS, KOHARU_HOME=$KOHARU_HOME"

ensure_rust
resolve_latest
log "Latest Koharu release: $KOHARU_TAG"
fetch_source
if ! build_runner; then
  [ "$KOHARU_TAG" != "$KNOWN_GOOD_TAG" ] || die "koharu-batch failed to build against Koharu $KOHARU_TAG"
  warn "koharu-batch does not build against Koharu $KOHARU_TAG yet, using $KNOWN_GOOD_TAG"
  KOHARU_TAG="$KNOWN_GOOD_TAG"; KOHARU_COMMIT="$KNOWN_GOOD_COMMIT"
  fetch_source
  build_runner || die "koharu-batch failed to build against Koharu $KOHARU_TAG"
fi
prune_sources

if [ "$DRY_RUN" = 1 ]; then
  RUNNER_VERSION="dry run"
  run "$RUNNER" --version
else
  RUNNER_VERSION="$("$RUNNER" --version)" || die "$RUNNER --version failed"
  log "Smoke test: $RUNNER_VERSION"
fi

install_plugin

if [ ! -f "$KOHARU_CONFIG" ]; then
  warn "$KOHARU_CONFIG not found. The translation model, provider and target language come from it: set them in the Koharu desktop app (Settings) or create the file. Without it Koharu downloads its default local model on the first run."
fi

if [ "$RESTART_GATEWAY" = 1 ]; then
  log "Restarting the Hermes gateway"
  hermes gateway restart
else
  log "Gateway not restarted (RESTART_GATEWAY=0). Run: $HERMES_BIN gateway restart"
fi

cat <<EOF

Koharu $KOHARU_TAG runner installed for Hermes.
  Runner:   $RUNNER ($RUNNER_VERSION)
  Exports:  $KOHARU_EXPORT_DIR
  Config:   $KOHARU_CONFIG (shared with the Koharu desktop app)
  Plugin:   $PLUGIN_DEST
Next: ask Hermes "translate the manga pages in <folder>".
EOF
