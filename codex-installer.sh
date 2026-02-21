#!/bin/sh
set -e

REPO="openai/codex"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
WRAPPER_REPO="${WRAPPER_REPO:-welidev/codex-installer}"
WRAPPER_RAW_URL="${WRAPPER_RAW_URL:-https://raw.githubusercontent.com/$WRAPPER_REPO/main/codex-installer.sh}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

# ── Resolve script location ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_REAL="$SCRIPT_DIR/codex-real"

# ── Color helpers (disabled when not a TTY) ────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; BOLD=''; NC=''
fi

info()  { printf "${BOLD}[info]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ ok ]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[warn]${NC}  %s\n" "$*" >&2; }
die()   { printf "${RED}[error]${NC} %s\n" "$*" >&2; exit 1; }

usage() {
  printf "Usage: %s [install|uninstall] [options]\n" "$(basename "$0")"
  printf "\n"
  printf "Commands:\n"
  printf "  install          Install or update the OpenAI Codex CLI (default)\n"
  printf "  uninstall        Remove the installed Codex CLI binary and wrapper\n"
  printf "  update-wrapper   Replace the wrapper script with the latest from GitHub\n"
  printf "\n"
  printf "Options:\n"
  printf "  --force, -f   Re-install even if already up to date\n"
  printf "  --yes,   -y   Skip confirmation prompts\n"
  printf "  --help,  -h   Show this help\n"
  printf "\n"
  printf "Environment:\n"
  printf "  INSTALL_DIR             Installation directory (default: /usr/local/bin)\n"
  printf "  CODEX_UPDATE_MODE       Update mode: auto|prompt|never (default: prompt)\n"
  printf "  CODEX_UPDATE_INTERVAL   Check interval: always|<duration> (default: 24h)\n"
  printf "  WRAPPER_REPO            GitHub repo for wrapper updates (default: welidev/codex-installer)\n"
}

# ── Confirmation prompt ────────────────────────────────────────────────────
confirm() {
  local question="$1"
  if [ "${YES:-0}" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    info "Non-interactive mode — proceeding automatically."
    return 0
  fi
  printf "${BOLD}  %s${NC} [y/N] " "$question" >&2
  read -r _reply
  case "$_reply" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) info "Aborted."; return 1 ;;
  esac
}

# ── Package manager hint ───────────────────────────────────────────────────
pkg_hint() {
  local pkg="$1"
  if   command -v apt-get  >/dev/null 2>&1; then echo "sudo apt-get install -y $pkg"
  elif command -v dnf      >/dev/null 2>&1; then echo "sudo dnf install -y $pkg"
  elif command -v yum      >/dev/null 2>&1; then echo "sudo yum install -y $pkg"
  elif command -v pacman   >/dev/null 2>&1; then echo "sudo pacman -S --noconfirm $pkg"
  elif command -v zypper   >/dev/null 2>&1; then echo "sudo zypper install -y $pkg"
  elif command -v apk      >/dev/null 2>&1; then echo "sudo apk add $pkg"
  elif command -v brew     >/dev/null 2>&1; then echo "brew install $pkg"
  else echo "install '$pkg' using your system package manager"
  fi
}

# ── Dependency check ──────────────────────────────────────────────────────
need() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  die "'$cmd' is required but not installed. Try: $(pkg_hint "$cmd")"
}

# ── HTTP fetch wrapper (curl preferred, wget fallback) ─────────────────────
http_get() {
  local url="$1" out="${2:-}"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$out" ]; then
      curl -fSL --progress-bar "$url" -o "$out"
    else
      curl -fsSL "$url"
    fi
  else
    if [ -n "$out" ]; then
      wget -q --show-progress -O "$out" "$url"
    else
      wget -qO- "$url"
    fi
  fi
}

http_get_quiet() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 3 --max-time 5 "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=5 "$url" 2>/dev/null
  else
    return 1
  fi
}

# ── Architecture detection ─────────────────────────────────────────────────
# Sets ARCH, LIBC, TRIPLE. Returns 1 on unsupported arch (caller decides
# whether to die or silently skip).
detect_arch() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)        ARCH_TRIPLE="x86_64-unknown-linux" ;;
    aarch64|arm64) ARCH_TRIPLE="aarch64-unknown-linux" ;;
    *) return 1 ;;
  esac

  LIBC="gnu"
  for _f in /lib/ld-musl-*.so*; do
    if [ -f "$_f" ]; then LIBC="musl"; break; fi
  done
  if [ "$LIBC" = "gnu" ] && \
     command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    LIBC="musl"
  fi
  unset _f

  TRIPLE="${ARCH_TRIPLE}-${LIBC}"
}

# ── Binary probe ──────────────────────────────────────────────────────────
# Finds an existing codex-real binary in well-known locations.
find_existing_real() {
  local bin=""
  for candidate in "$INSTALL_DIR/codex-real" "$HOME/.local/bin/codex-real"; do
    [ -x "$candidate" ] && { bin="$candidate"; break; }
  done
  printf '%s' "$bin"
}

# ── Config path resolution ────────────────────────────────────────────────
# Sets CONFIG_DIR (system or user, depending on install location) and
# USER_CONFIG_DIR (always per-user).
resolve_config_dirs() {
  USER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/codex-wrapper"
  case "$SCRIPT_DIR" in
    "$HOME"*) CONFIG_DIR="$USER_CONFIG_DIR" ;;
    *)        CONFIG_DIR="/etc/codex-wrapper" ;;
  esac
}

# ── Parse human-readable interval to seconds ──────────────────────────────
# Accepts "always", "0", or "<number><unit>" where unit is one of:
#   s/sec/seconds, m/min/minutes, h/hr/hours, d/day/days, w/wk/weeks
# Compact ("24h") and spaced ("24 hours") forms both work.
parse_interval() {
  local input="$1"
  case "$input" in
    always|0) printf '0'; return ;;
  esac

  local num unit
  num=$(printf '%s' "$input" | sed 's/[^0-9]//g')
  unit=$(printf '%s' "$input" | sed 's/[0-9 ]//g' | tr '[:upper:]' '[:lower:]')

  [ -n "$num" ] || { printf '86400'; return; }

  case "$unit" in
    s|sec|secs|second|seconds)   printf '%s' "$((num))" ;;
    m|min|mins|minute|minutes)   printf '%s' "$((num * 60))" ;;
    h|hr|hrs|hour|hours)         printf '%s' "$((num * 3600))" ;;
    d|day|days)                  printf '%s' "$((num * 86400))" ;;
    w|wk|wks|week|weeks)         printf '%s' "$((num * 604800))" ;;
    *)                           printf '86400' ;;
  esac
}

# ── Load wrapper config ───────────────────────────────────────────────────
# Reads config files and applies environment variable overrides.
# Sets UPDATE_MODE and UPDATE_INTERVAL.
load_config() {
  UPDATE_MODE="prompt"
  UPDATE_INTERVAL="24h"

  resolve_config_dirs

  if [ "$CONFIG_DIR" != "$USER_CONFIG_DIR" ] && [ -f "$CONFIG_DIR/config" ]; then
    . "$CONFIG_DIR/config" || true
  fi

  if [ -f "$USER_CONFIG_DIR/config" ]; then
    . "$USER_CONFIG_DIR/config" || true
  fi

  UPDATE_MODE="${CODEX_UPDATE_MODE:-$UPDATE_MODE}"
  UPDATE_INTERVAL="${CODEX_UPDATE_INTERVAL:-$UPDATE_INTERVAL}"
}

# ── Create default config file ────────────────────────────────────────────
create_default_config() {
  resolve_config_dirs
  local cfg_file="$CONFIG_DIR/config"

  [ -f "$cfg_file" ] && return 0

  if [ ! -d "$CONFIG_DIR" ]; then
    if [ -w "$(dirname "$CONFIG_DIR")" ] || [ "$CONFIG_DIR" = "$USER_CONFIG_DIR" ]; then
      mkdir -p "$CONFIG_DIR"
    elif command -v sudo >/dev/null 2>&1; then
      sudo mkdir -p "$CONFIG_DIR" 2>/dev/null || { warn "Cannot create config directory: $CONFIG_DIR"; return 0; }
    else
      warn "Cannot create config directory: $CONFIG_DIR"
      return 0
    fi
  fi

  local config_content
  config_content=$(cat <<'CFGEOF'
# Codex wrapper configuration
#
# UPDATE_MODE: auto | prompt | never  (default: prompt)
#   auto   - upgrade automatically without asking
#   prompt - ask before upgrading (TTY only)
#   never  - never check for updates
# UPDATE_MODE=prompt
#
# UPDATE_INTERVAL: always | <N><unit>  (default: 24h)
#   Examples: 24h, 30m, 7d, 1w, "24 hours", "1 week"
# UPDATE_INTERVAL=24h
CFGEOF
)

  if [ -w "$CONFIG_DIR" ]; then
    printf '%s\n' "$config_content" > "$cfg_file"
  elif command -v sudo >/dev/null 2>&1; then
    printf '%s\n' "$config_content" | sudo tee "$cfg_file" >/dev/null 2>&1 || true
  fi
}

# ── Upgrade codex-real in place ────────────────────────────────────────────
do_upgrade() {
  local tag="$1" latest_ver="$2" current_ver="$3"

  detect_arch || return 1

  local url="https://github.com/$REPO/releases/download/$tag/codex-${TRIPLE}.tar.gz"
  local tmpdir
  tmpdir=$(mktemp -d) || return 1

  info "Downloading codex $latest_ver …"
  if ! http_get "$url" "$tmpdir/codex.tar.gz"; then
    rm -rf "$tmpdir"
    warn "Download failed."
    return 1
  fi

  tar -xzf "$tmpdir/codex.tar.gz" -C "$tmpdir" || { rm -rf "$tmpdir"; return 1; }

  local new_binary="$tmpdir/codex-${TRIPLE}"
  [ -f "$new_binary" ] || new_binary="$tmpdir/codex"
  [ -f "$new_binary" ] || { rm -rf "$tmpdir"; return 1; }
  chmod +x "$new_binary"

  local target_dir
  target_dir=$(dirname "$CODEX_REAL")
  if [ -w "$target_dir" ]; then
    mv "$new_binary" "$CODEX_REAL"
  elif command -v sudo >/dev/null 2>&1; then
    if [ -t 0 ]; then
      info "Writing to $target_dir requires elevated privileges…"
      sudo mv "$new_binary" "$CODEX_REAL" || { rm -rf "$tmpdir"; return 1; }
    elif sudo -n mv "$new_binary" "$CODEX_REAL" 2>/dev/null; then
      :
    else
      rm -rf "$tmpdir"; return 1
    fi
  else
    rm -rf "$tmpdir"; return 1
  fi

  rm -rf "$tmpdir"
  ok "Updated codex $current_ver → $latest_ver"
}

# ── Self-update the wrapper script ────────────────────────────────────────
do_update_wrapper() {
  info "Fetching latest wrapper from github.com/$WRAPPER_REPO …"

  local tmpfile
  tmpfile=$(mktemp) || die "Failed to create temp file."

  if ! http_get "$WRAPPER_RAW_URL" "$tmpfile"; then
    rm -f "$tmpfile"
    die "Download failed. Check your internet connection."
  fi

  if [ ! -s "$tmpfile" ] || ! head -1 "$tmpfile" | grep -q '^#!/bin/sh'; then
    rm -f "$tmpfile"
    die "Downloaded file does not appear to be a valid wrapper script."
  fi

  chmod +x "$tmpfile"

  local target="$SCRIPT_DIR/codex"
  local target_dir="$SCRIPT_DIR"
  if [ -w "$target_dir" ]; then
    mv "$tmpfile" "$target"
  elif command -v sudo >/dev/null 2>&1; then
    if [ -t 0 ]; then
      info "Writing to $target_dir requires elevated privileges…"
      sudo mv "$tmpfile" "$target" || { rm -f "$tmpfile"; die "Failed to update wrapper."; }
    elif sudo -n mv "$tmpfile" "$target" 2>/dev/null; then
      :
    else
      rm -f "$tmpfile"
      die "Cannot write to $target_dir (directory not writable and passwordless sudo unavailable)."
    fi
  else
    rm -f "$tmpfile"
    die "Cannot write to $target_dir (directory not writable and sudo not available)."
  fi

  ok "Wrapper updated from $WRAPPER_REPO."
}

# ── Check for updates (cached) and act based on UPDATE_MODE ───────────────
check_and_update() {
  [ "$UPDATE_MODE" != "never" ] || return 0

  local interval_secs
  interval_secs=$(parse_interval "$UPDATE_INTERVAL")

  local cache_file="$USER_CONFIG_DIR/last_check"
  if [ "$interval_secs" -gt 0 ] && [ -f "$cache_file" ]; then
    local last_check now elapsed
    last_check=$(cat "$cache_file" 2>/dev/null || printf '0')
    case "$last_check" in *[!0-9]*) last_check=0 ;; esac
    now=$(date +%s)
    elapsed=$((now - last_check))
    [ "$elapsed" -ge "$interval_secs" ] || return 0
  fi

  mkdir -p "$USER_CONFIG_DIR" 2>/dev/null || true
  date +%s > "$cache_file" 2>/dev/null || true

  command -v jq >/dev/null 2>&1 || return 0

  local release_json tag latest_ver current_ver
  release_json=$(http_get_quiet "$API_URL") || return 0
  tag=$(printf '%s' "$release_json" | jq -r '.tag_name // empty' 2>/dev/null) || return 0
  [ -n "$tag" ] || return 0

  latest_ver="${tag#rust-v}"
  latest_ver="${latest_ver#v}"

  current_ver=$("$CODEX_REAL" --version 2>/dev/null | awk '{print $NF}') || return 0
  [ -n "$current_ver" ] || return 0
  [ "$current_ver" != "$latest_ver" ] || return 0

  if [ "$UPDATE_MODE" = "auto" ]; then
    do_upgrade "$tag" "$latest_ver" "$current_ver"
  elif [ -t 1 ] && [ -t 0 ]; then
    printf "${BOLD}[codex-wrapper]${NC} Update available: %s → %s\n" "$current_ver" "$latest_ver" >&2
    printf "${BOLD}  Upgrade?${NC} [y/N] " >&2
    read -r _reply
    case "$_reply" in
      [Yy]|[Yy][Ee][Ss]) do_upgrade "$tag" "$latest_ver" "$current_ver" ;;
    esac
  fi
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
  YES=0
  for arg in "$@"; do
    case "$arg" in
      --yes|-y)  YES=1 ;;
      --help|-h) usage; exit 0 ;;
    esac
  done

  local wrapper_bin="$SCRIPT_DIR/codex"
  local real_bin="$CODEX_REAL"

  # In installer mode codex-real isn't beside us; search known locations.
  if [ ! -f "$real_bin" ]; then
    real_bin=$(find_existing_real)
    if [ -n "$real_bin" ]; then
      wrapper_bin="$(dirname "$real_bin")/codex"
    fi
  fi

  local found=0
  [ -f "$wrapper_bin" ] && found=1
  [ -f "$real_bin" ]    && found=1

  if [ "$found" -eq 0 ]; then
    warn "codex does not appear to be installed."
    exit 0
  fi

  info "Found files to remove:"
  [ -f "$wrapper_bin" ] && info "  $wrapper_bin"
  [ -f "$real_bin" ]    && info "  $real_bin"

  local installed_dir
  installed_dir=$(dirname "${real_bin:-$wrapper_bin}")
  local saved_dir="$SCRIPT_DIR"
  SCRIPT_DIR="$installed_dir"
  resolve_config_dirs
  SCRIPT_DIR="$saved_dir"

  local has_config=0
  if [ -d "$CONFIG_DIR" ] || [ -d "$USER_CONFIG_DIR" ]; then
    has_config=1
    [ -d "$CONFIG_DIR" ] && info "  $CONFIG_DIR/"
    [ -d "$USER_CONFIG_DIR" ] && [ "$USER_CONFIG_DIR" != "$CONFIG_DIR" ] && info "  $USER_CONFIG_DIR/"
  fi

  printf "\n"
  confirm "Remove codex?" || exit 0

  _rm_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    local d
    d=$(dirname "$f")
    if [ -w "$d" ]; then
      rm "$f"
    elif command -v sudo >/dev/null 2>&1; then
      if [ -t 0 ]; then
        info "Removing $f requires elevated privileges…"
        sudo rm "$f"
      elif sudo -n rm "$f" 2>/dev/null; then
        :
      else
        warn "Cannot remove $f (directory not writable and passwordless sudo unavailable)."
        return 1
      fi
    else
      warn "Cannot remove $f (directory not writable and sudo not available)."
      return 1
    fi
  }

  _rm_file "$real_bin" || true
  _rm_file "$wrapper_bin" || true

  if [ "$has_config" -eq 1 ]; then
    printf "\n"
    if confirm "Also remove configuration?"; then
      if [ -d "$CONFIG_DIR" ]; then
        if [ -w "$CONFIG_DIR" ] || [ -w "$(dirname "$CONFIG_DIR")" ]; then
          rm -rf "$CONFIG_DIR"
        elif command -v sudo >/dev/null 2>&1; then
          sudo rm -rf "$CONFIG_DIR" 2>/dev/null || true
        fi
      fi
      if [ -d "$USER_CONFIG_DIR" ] && [ "$USER_CONFIG_DIR" != "$CONFIG_DIR" ]; then
        rm -rf "$USER_CONFIG_DIR" 2>/dev/null || true
      fi
      ok "Configuration removed."
    fi
  fi

  ok "Codex has been uninstalled."
  exit 0
}

# ── Installer main ────────────────────────────────────────────────────────
installer_main() {
  FORCE=0
  YES=0
  for arg in "$@"; do
    case "$arg" in
      --force|-f) FORCE=1 ;;
      --yes|-y)   YES=1 ;;
      --help|-h)  usage; exit 0 ;;
      *) die "Unknown argument: $arg  (try --help)" ;;
    esac
  done

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "'curl' or 'wget' is required. Try: $(pkg_hint curl)"
  fi
  need jq
  need tar

  detect_arch || die "Unsupported architecture: $(uname -m) (only x86_64 and aarch64 have releases)"

  info "Fetching latest release from github.com/$REPO …"
  RELEASE_JSON=$(http_get "$API_URL") \
    || die "Failed to reach GitHub API. Check your internet connection."

  TAG=$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name // empty')
  [ -n "$TAG" ] || die "Could not parse the latest release tag from GitHub."

  LATEST_VER="${TAG#rust-v}"
  LATEST_VER="${LATEST_VER#v}"

  CURRENT_VER=""
  EXISTING_BIN=$(find_existing_real)

  if [ -n "$EXISTING_BIN" ]; then
    CURRENT_VER=$("$EXISTING_BIN" --version 2>/dev/null | awk '{print $NF}' || true)
    if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$LATEST_VER" ]; then
      if [ "$FORCE" -eq 0 ]; then
        ok "Already up to date: codex $CURRENT_VER  ($EXISTING_BIN)"
        exit 0
      else
        info "Already at $CURRENT_VER — re-installing because --force was passed."
      fi
    else
      info "Updating codex ${CURRENT_VER:-<unknown>} → $LATEST_VER"
    fi
  fi

  URL="https://github.com/$REPO/releases/download/$TAG/codex-${TRIPLE}.tar.gz"

  if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" != "$LATEST_VER" ]; then
    _action="Update  codex $CURRENT_VER → $LATEST_VER"
  elif [ "$FORCE" -eq 1 ]; then
    _action="Re-install codex $LATEST_VER"
  else
    _action="Install codex $LATEST_VER"
  fi

  printf "\n"
  printf "  ${BOLD}Action :${NC} %s\n" "$_action"
  printf "  ${BOLD}Arch   :${NC} %s (%s)\n" "$ARCH" "$LIBC"
  printf "  ${BOLD}Target :${NC} %s  ${YELLOW}(falls back to ~/.local/bin if not writable)${NC}\n" "$INSTALL_DIR"
  printf "  ${BOLD}Source :${NC} %s\n" "$URL"
  printf "\n"
  unset _action

  confirm "Proceed with installation?" || exit 0

  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT

  ARCHIVE="$WORKDIR/codex.tar.gz"
  info "Downloading…"
  if ! http_get "$URL" "$ARCHIVE"; then
    die "Download failed for $TRIPLE.\nCheck available assets at: https://github.com/$REPO/releases/tag/$TAG"
  fi

  info "Extracting…"
  tar -xzf "$ARCHIVE" -C "$WORKDIR" \
    || die "Failed to extract archive. The file may be corrupt."

  BINARY="$WORKDIR/codex-${TRIPLE}"
  [ -f "$BINARY" ] || BINARY="$WORKDIR/codex"
  [ -f "$BINARY" ] || die "No binary found in archive. Contents: $(ls "$WORKDIR")"
  chmod +x "$BINARY"

  # Place binary as codex-real and wrapper as codex into a target directory.
  # Uses sudo when the directory isn't writable.
  try_install() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    if [ -w "$dir" ]; then
      mv "$BINARY" "$dir/codex-real" && return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
      if [ -t 0 ]; then
        info "Writing to $dir requires elevated privileges…"
        sudo mv "$BINARY" "$dir/codex-real" && return 0
      elif sudo -n mv "$BINARY" "$dir/codex-real" 2>/dev/null; then
        return 0
      fi
    fi
    return 1
  }

  install_wrapper() {
    local dir="$1"
    local src tmpwrapper=""
    src=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")

    # When piped (curl | sh), $0 is "sh" — download the wrapper instead.
    if [ ! -f "$src" ] || ! head -1 "$src" 2>/dev/null | grep -q '^#!/bin/sh'; then
      tmpwrapper=$(mktemp) || return 1
      info "Downloading wrapper script …"
      if ! http_get "$WRAPPER_RAW_URL" "$tmpwrapper"; then
        rm -f "$tmpwrapper"
        warn "Failed to download wrapper from $WRAPPER_RAW_URL"
        return 1
      fi
      src="$tmpwrapper"
    fi

    local ok=0
    if [ -w "$dir" ]; then
      cp "$src" "$dir/codex" && chmod +x "$dir/codex" && ok=1
    elif command -v sudo >/dev/null 2>&1; then
      if [ -t 0 ]; then
        sudo cp "$src" "$dir/codex" && sudo chmod +x "$dir/codex" && ok=1
      elif sudo -n cp "$src" "$dir/codex" 2>/dev/null; then
        sudo -n chmod +x "$dir/codex" 2>/dev/null
        ok=1
      fi
    fi

    [ -n "$tmpwrapper" ] && rm -f "$tmpwrapper"
    [ "$ok" -eq 1 ] && return 0
    return 1
  }

  INSTALLED_DIR=""
  if try_install "$INSTALL_DIR"; then
    INSTALLED_DIR="$INSTALL_DIR"
    ok "Installed binary → $INSTALLED_DIR/codex-real"
  else
    LOCAL_BIN="$HOME/.local/bin"
    warn "Cannot write to $INSTALL_DIR (not writable or sudo requires a TTY)."
    warn "Falling back to $LOCAL_BIN"
    mkdir -p "$LOCAL_BIN"
    try_install "$LOCAL_BIN" || die "Could not install to $LOCAL_BIN either."
    INSTALLED_DIR="$LOCAL_BIN"
    ok "Installed binary → $INSTALLED_DIR/codex-real"
    case ":$PATH:" in
      *":$LOCAL_BIN:"*) ;;
      *) warn "$LOCAL_BIN is not in your \$PATH."
         warn "Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
         warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
         ;;
    esac
  fi

  install_wrapper "$INSTALLED_DIR" \
    || die "Could not install wrapper to $INSTALLED_DIR."
  ok "Installed wrapper → $INSTALLED_DIR/codex"

  local saved_dir="$SCRIPT_DIR"
  SCRIPT_DIR="$INSTALLED_DIR"
  create_default_config
  SCRIPT_DIR="$saved_dir"

  VERSION=$("$INSTALLED_DIR/codex-real" --version 2>/dev/null | awk '{print $NF}' || true)
  if [ -n "$CURRENT_VER" ] && [ -n "$VERSION" ]; then
    ok "Updated codex $CURRENT_VER → $VERSION"
  else
    [ -n "$VERSION" ] && ok "Version: $VERSION"
    ok "Done! Run 'codex' to get started."
  fi
}

# ── Wrapper main ──────────────────────────────────────────────────────────
wrapper_main() {
  load_config
  check_and_update || true
  exec "$CODEX_REAL" "$@"
}

# ── Mode detection & dispatch ─────────────────────────────────────────────
if [ -x "$CODEX_REAL" ]; then
  case "${1:-}" in
    install)        shift; installer_main "$@" ;;
    uninstall)      shift; do_uninstall "$@" ;;
    update-wrapper) shift; do_update_wrapper "$@" ;;
    *)              wrapper_main "$@" ;;
  esac
else
  case "${1:-}" in
    uninstall) shift; do_uninstall "$@" ;;
    install)   shift; installer_main "$@" ;;
    *)         installer_main "$@" ;;
  esac
fi
