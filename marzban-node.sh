#!/usr/bin/env bash
set -euo pipefail

# ===================== GLOBAL VARS =====================
CORE_REPO="${CORE_REPO:-GFW-knocker/Xray-core}"     # GitHub repo for Xray binaries
LAST_XRAY_CORES="${LAST_XRAY_CORES:-5}"             # how many recent releases to consider for "latest"
INSTALL_DIR="${INSTALL_DIR:-/opt}"
APP_NAME="${APP_NAME:-marzban-node}"
COMPOSE_FILE="${COMPOSE_FILE:-$INSTALL_DIR/$APP_NAME/docker-compose.yml}"

DATA_MAIN_DIR="${DATA_MAIN_DIR:-/var/lib/marzban-node}"  # host bind that must be mounted
XRAY_DEST_PATH_IN_CONTAINER="${XRAY_DEST_PATH_IN_CONTAINER:-/var/lib/marzban-node/xray-core/xray}"

# Non-interactive version selection:
#   - arg 2:  explicit version (e.g., v1.25.8-mahsa-r1)
#   - env XRAY_VERSION: fallback
#   - otherwise: auto-latest from GitHub releases
# ======================================================

colorized_echo() {
  local color="${1:-}"; shift || true
  local text="${*:-}"
  case "$color" in
    red)     printf "\e[1;91m%s\e[0m\n" "$text" ;;
    green)   printf "\e[1;92m%s\e[0m\n" "$text" ;;
    yellow)  printf "\e[1;93m%s\e[0m\n" "$text" ;;
    blue)    printf "\e[1;94m%s\e[0m\n" "$text" ;;
    magenta) printf "\e[1;95m%s\e[0m\n" "$text" ;;
    cyan)    printf "\e[1;96m%s\e[0m\n" "$text" ;;
    *) echo "$text" ;;
  esac
}

check_root() { [ "$(id -u)" -eq 0 ] || { colorized_echo red "Must run as root."; exit 1; }; }

# --------------- Package manager + installs ---------------
PKG_MGR=""
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
  elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
  else colorized_echo red "No supported package manager (apt/dnf/yum/apk)."; exit 1; fi
}

install_package() {
  detect_pkg_mgr
  case "$PKG_MGR" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -y || true
         DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
  esac
}

ensure_tools() {
  command -v curl >/dev/null 2>&1 || install_package curl ca-certificates
  command -v jq   >/dev/null 2>&1 || install_package jq || true
  if ! command -v yq >/dev/null 2>&1; then
    # try repo package; if not available, fall back to static binary
    if ! install_package yq 2>/dev/null; then
      local arch dl_arch
      arch="$(uname -m)"
      case "$arch" in
        x86_64|amd64) dl_arch="amd64" ;;
        aarch64|arm64) dl_arch="arm64" ;;
        armv7l|armv7) dl_arch="arm" ;;
        i386|i686) dl_arch="386" ;;
        *) dl_arch="amd64" ;;
      esac
      curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${dl_arch}"
      chmod +x /usr/local/bin/yq
    fi
  fi
  command -v unzip >/dev/null 2>&1 || install_package unzip || true
  command -v tar   >/dev/null 2>&1 || install_package tar || true
}

# --------------- Docker compose wrapper ---------------
docker_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose "$@"; return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"; return
  fi
  colorized_echo yellow "Docker Compose not found. Installing docker.io and plugin…"
  if command -v apt-get >/dev/null 2>&1; then
    install_package docker.io docker-compose-plugin || install_package docker.io
    systemctl enable --now docker || true
  else
    colorized_echo red "Install Docker & Compose for your distro, then re-run."
    exit 1
  fi
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

# --------------- Arch detect ---------------
ARCH=""
detect_arch() {
  [ "$(uname -s)" = "Linux" ] || { echo "Unsupported OS"; exit 1; }
  case "$(uname -m)" in
    amd64|x86_64) ARCH='64' ;;
    aarch64|arm64) ARCH='arm64-v8a' ;;
    i386|i686) ARCH='32' ;;
    *) echo "Unsupported arch: $(uname -m)"; exit 1 ;;
  esac
}

# --------------- GitHub API helpers ---------------
gh_api() {
  # Uses GH_TOKEN if present for higher rate limits
  local url="$1"
  if [ -n "${GH_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$url"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$url"
  fi
}

get_latest_tag() {
  # returns tag_name of latest release
  gh_api "https://api.github.com/repos/${CORE_REPO}/releases?per_page=1" \
    | jq -r '.[0].tag_name'
}

# --------------- Xray version helpers ---------------
current_xray_version() {
  local bin="$DATA_MAIN_DIR/xray-core/xray"
  [ -x "$bin" ] && "$bin" -version 2>/dev/null | head -n1 | awk '{print $2}' || echo "Not installed"
}

fetch_xray_core() {
  detect_arch
  ensure_tools

  local version="${1:-}"
  if [ -z "$version" ] || [ "$version" = "latest" ]; then
    version="$(get_latest_tag)"
    [ -n "$version" ] && [ "$version" != "null" ] || { colorized_echo red "Failed to resolve latest release tag."; exit 1; }
  fi
  colorized_echo blue "Selected version: $version"

  mkdir -p "$DATA_MAIN_DIR/xray-core"
  cd "$DATA_MAIN_DIR/xray-core"

  local assets_json zip_name tgz_name url
  assets_json="$(gh_api "https://api.github.com/repos/${CORE_REPO}/releases/tags/${version}")"
  zip_name="Xray-linux-$ARCH.zip"
  tgz_name="Xray-linux-$ARCH.tar.gz"

  url="$(echo "$assets_json" | jq -r --arg z "$zip_name" --arg t "$tgz_name" '
    (.assets[]? | select(.name==$t) | .browser_download_url) //
    (.assets[]? | select(.name==$z) | .browser_download_url) // empty
  ')"

  [ -n "$url" ] && [ "$url" != "null" ] || { colorized_echo red "No asset found for linux-$ARCH in $version."; exit 1; }

  colorized_echo cyan "Downloading: $url"
  curl -fL --retry 3 -o xray_pkg "$url"

  rm -f ./xray 2>/dev/null || true
  if [[ "$url" =~ \.tar\.gz$ ]]; then
    tar -xzf xray_pkg
  else
    unzip -o xray_pkg >/dev/null 2>&1
  fi
  rm -f xray_pkg

  [ -x "./xray" ] || { colorized_echo red "xray binary not found after extraction."; exit 1; }
  colorized_echo green "Xray core unpacked to $DATA_MAIN_DIR/xray-core"
}

# --------------- Compose edits ---------------
ensure_compose_edits() {
  [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found: $COMPOSE_FILE"; exit 1; }
  # Set XRAY path
  yq -y -i '.services."marzban-node".environment.XRAY_EXECUTABLE_PATH = strenv(XRAY_DEST_PATH_IN_CONTAINER)' "$COMPOSE_FILE"
  # Ensure volumes array exists
  if ! yq '.services."marzban-node".volumes' "$COMPOSE_FILE" >/dev/null 2>&1; then
    yq -y -i '.services."marzban-node".volumes = []' "$COMPOSE_FILE"
  fi
  # Append bind mount if missing
  if ! yq -e ".services.\"marzban-node\".volumes[] | select(. == \"${DATA_MAIN_DIR}:/var/lib/marzban-node\")" "$COMPOSE_FILE" >/dev/null 2>&1; then
    yq -y -i ".services.\"marzban-node\".volumes += [\"${DATA_MAIN_DIR}:/var/lib/marzban-node\"]" "$COMPOSE_FILE"
  fi
}

# --------------- Commands ---------------
cmd_core_update() {
  check_root
  local version="${1:-${XRAY_VERSION:-latest}}"
  fetch_xray_core "$version"
  ensure_compose_edits
  colorized_echo blue "Restarting container…"
  docker_compose -f "$COMPOSE_FILE" -p "$APP_NAME" restart
  colorized_echo green "✅ Updated to $(current_xray_version)"
}

usage() {
  cat <<EOF
Usage:
  $0 core-update [version]
    - version: tag name in ${CORE_REPO} (e.g., v1.25.8-mahsa-r1). If omitted, uses latest.

Env overrides:
  CORE_REPO, LAST_XRAY_CORES, INSTALL_DIR, APP_NAME, COMPOSE_FILE, DATA_MAIN_DIR, XRAY_DEST_PATH_IN_CONTAINER, XRAY_VERSION

Current Xray-core: $(current_xray_version)
EOF
}

# --------------- Main ---------------
CMD="${1:-}"
ARG2="${2:-}"
case "$CMD" in
  core-update) shift; cmd_core_update "${ARG2:-}";;
  *) usage ;;
esac
