#!/usr/bin/env bash
set -euo pipefail

# ============ GLOBAL VARS ============
CORE_REPO="GFW-knocker/Xray-core"    # fork to use for Xray binaries
LAST_XRAY_CORES=5
INSTALL_DIR="/opt"
DATA_DIR="/var/lib/marzban-node"
DATA_MAIN_DIR="/var/lib/marzban-node"
CERT_FILE="$DATA_DIR/cert.pem"
APP_NAME="marzban-node"
COMPOSE_FILE="$INSTALL_DIR/$APP_NAME/docker-compose.yml"
SCRIPT_URL="https://github.com/$CORE_REPO/raw/master/marzban-node.sh"
# =====================================

colorized_echo() {
  local color=${1:-}
  local text=${2:-}
  local style=${3:-0}
  case "$color" in
    red)     printf "\e[%s;91m%s\e[0m\n" "$style" "$text" ;;
    green)   printf "\e[%s;92m%s\e[0m\n" "$style" "$text" ;;
    yellow)  printf "\e[%s;93m%s\e[0m\n" "$style" "$text" ;;
    blue)    printf "\e[%s;94m%s\e[0m\n" "$style" "$text" ;;
    magenta) printf "\e[%s;95m%s\e[0m\n" "$style" "$text" ;;
    cyan)    printf "\e[%s;96m%s\e[0m\n" "$style" "$text" ;;
    *) echo "$text" ;;
  esac
}

check_running_as_root() {
  if [ "$(id -u)" != "0" ]; then
    colorized_echo red "This command must be run as root."
    exit 1
  fi
}

# --- pkg manager detection + install ---
PKG_MGR=""
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  else
    colorized_echo red "No supported package manager found (apt/dnf/yum/apk)."
    exit 1
  fi
}

install_package() {
  detect_pkg_mgr
  case "$PKG_MGR" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
  esac
}

ensure_tools() {
  # curl
  command -v curl >/dev/null 2>&1 || install_package curl ca-certificates
  # jq
  command -v jq >/dev/null 2>&1 || install_package jq
  # yq
  if ! command -v yq >/dev/null 2>&1; then
    # try package first; if not found, install yq binary
    if ! install_package yq 2>/dev/null; then
      ARCH_DL="$(uname -m)"
      case "$ARCH_DL" in
        x86_64|amd64) YQ_ARCH="amd64" ;;
        aarch64|arm64) YQ_ARCH="arm64" ;;
        armv7l|armv7) YQ_ARCH="arm" ;;
        i386|i686) YQ_ARCH="386" ;;
        *) colorized_echo yellow "Unknown arch for yq; attempting amd64"; YQ_ARCH="amd64" ;;
      esac
      curl -L -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}"
      chmod +x /usr/local/bin/yq
    fi
  fi
  # unzip/tar
  command -v unzip >/dev/null 2>&1 || install_package unzip || true
  command -v tar   >/dev/null 2>&1 || install_package tar || true
}

# --- docker compose wrapper ---
docker_compose() {
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      docker compose "$@"
      return
    fi
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
    return
  fi
  colorized_echo yellow "Docker Compose not found. Installing docker.io & plugin…"
  if command -v apt-get >/dev/null 2>&1; then
    install_package docker.io docker-compose-plugin || install_package docker.io
  else
    colorized_echo red "Please install Docker & Compose for your distro and re-run."
    exit 1
  fi
  systemctl enable --now docker || true
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

# --- detect arch ---
ARCH=""
identify_the_operating_system_and_architecture() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "error: unsupported OS"; exit 1
  fi
  case "$(uname -m)" in
    amd64|x86_64) ARCH='64' ;;
    aarch64|arm64) ARCH='arm64-v8a' ;;
    i386|i686) ARCH='32' ;;
    *) echo "error: unsupported arch $(uname -m)"; exit 1 ;;
  esac
}

# --- get current xray version ---
get_current_xray_core_version() {
  local XRAY_BINARY="$DATA_MAIN_DIR/xray-core/xray"
  if [ -f "$XRAY_BINARY" ]; then
    "$XRAY_BINARY" -version 2>/dev/null | head -n1 | awk '{print $2}'
    return
  fi
  echo "Not installed"
}

# --- fetch & unpack xray core ---
get_xray_core() {
  identify_the_operating_system_and_architecture
  ensure_tools

  local releases
  releases="$(curl -fsSL "https://api.github.com/repos/${CORE_REPO}/releases?per_page=${LAST_XRAY_CORES}")"
  local -a versions
  mapfile -t versions < <(echo "$releases" | jq -r '.[].tag_name' | sed '/^null$/d')

  if [ "${#versions[@]}" -eq 0 ]; then
    colorized_echo red "Could not read releases from ${CORE_REPO} (rate limit?)."
    exit 1
  fi

  colorized_echo green "Available Xray-core versions from ${CORE_REPO}:"
  local i=0
  for v in "${versions[@]}"; do
    i=$((i+1)); echo "$i. $v"
  done

  local choice selected_version
  read -rp "Choose version [1-${#versions[@]}] or enter manually: " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#versions[@]}" ]; then
    selected_version="${versions[$((choice-1))]}"
  else
    selected_version="$choice"
  fi

  colorized_echo blue "Selected version: $selected_version"

  mkdir -p "$DATA_MAIN_DIR/xray-core"
  cd "$DATA_MAIN_DIR/xray-core"

  local assets_json
  assets_json="$(curl -fsSL "https://api.github.com/repos/${CORE_REPO}/releases/tags/${selected_version}")"

  local zip_name="Xray-linux-$ARCH.zip"
  local tgz_name="Xray-linux-$ARCH.tar.gz"

  local xray_download_url
  xray_download_url="$(echo "$assets_json" | jq -r --arg z "$zip_name" --arg t "$tgz_name" '
      (.assets[]? | select(.name==$t) | .browser_download_url) //
      (.assets[]? | select(.name==$z) | .browser_download_url) // empty
    ')"

  if [ -z "$xray_download_url" ] || [ "$xray_download_url" = "null" ]; then
    colorized_echo red "No asset found for linux-$ARCH in $selected_version."
    exit 1
  fi

  colorized_echo cyan "Downloading: $xray_download_url"
  curl -fL --retry 3 -o xray_pkg "$xray_download_url"

  # clean previous extracted files except config dir
  rm -f ./xray 2>/dev/null || true

  if [[ "$xray_download_url" =~ \.tar\.gz$ ]]; then
    tar -xzf xray_pkg
  else
    unzip -o xray_pkg >/dev/null 2>&1
  fi
  rm -f xray_pkg

  if [ ! -x "./xray" ]; then
    colorized_echo red "xray binary not found after extraction."
    exit 1
  fi
}

# --- core update command ---
update_core_command() {
  check_running_as_root
  get_xray_core
  ensure_tools

  if [ ! -f "$COMPOSE_FILE" ]; then
    colorized_echo red "Compose file not found: $COMPOSE_FILE"
    exit 1
  fi

  # Set XRAY path inside container
  yq -i '.services."marzban-node".environment.XRAY_EXECUTABLE_PATH = "/var/lib/marzban-node/xray-core/xray"' "$COMPOSE_FILE"

  # Ensure DATA_MAIN_DIR is mounted
  # If volumes key is missing, create it as an array, then append bind
  if ! yq '.services."marzban-node".volumes' "$COMPOSE_FILE" >/dev/null 2>&1; then
    yq -i '.services."marzban-node".volumes = []' "$COMPOSE_FILE"
  fi
  # Append only if not present
  if ! yq -e ".services.\"marzban-node\".volumes[] | select(. == \"${DATA_MAIN_DIR}:/var/lib/marzban-node\")" "$COMPOSE_FILE" >/dev/null 2>&1; then
    yq -i ".services.\"marzban-node\".volumes += [\"${DATA_MAIN_DIR}:/var/lib/marzban-node\"]" "$COMPOSE_FILE"
  fi

  colorized_echo blue "Restarting container…"
  docker_compose -f "$COMPOSE_FILE" -p "$APP_NAME" restart

  colorized_echo green "✅ Updated to Xray-core from ${CORE_REPO}."
  colorized_echo green "Current core: $(get_current_xray_core_version)"
}

# --- usage/help ---
usage() {
  echo "Usage: $APP_NAME [core-update]"
  echo "Current Xray-core: $(get_current_xray_core_version)"
}

# --- main dispatcher ---
COMMAND="${1:-}"
case "$COMMAND" in
  core-update) update_core_command ;;
  *) usage ;;
esac
