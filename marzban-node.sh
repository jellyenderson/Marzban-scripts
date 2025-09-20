#!/usr/bin/env bash
set -e

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
    local color=$1
    local text=$2
    local style=${3:-0}
    case $color in
        "red") printf "\e[${style};91m${text}\e[0m\n" ;;
        "green") printf "\e[${style};92m${text}\e[0m\n" ;;
        "yellow") printf "\e[${style};93m${text}\e[0m\n" ;;
        "blue") printf "\e[${style};94m${text}\e[0m\n" ;;
        "magenta") printf "\e[${style};95m${text}\e[0m\n" ;;
        "cyan") printf "\e[${style};96m${text}\e[0m\n" ;;
        *) echo "${text}" ;;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

# --- detect arch ---
identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'amd64'|'x86_64') ARCH='64' ;;
            'aarch64'|'armv8') ARCH='arm64-v8a' ;;
            'i386'|'i686') ARCH='32' ;;
            *) echo "error: unsupported arch"; exit 1 ;;
        esac
    else
        echo "error: unsupported OS"; exit 1
    fi
}

# --- get current xray version ---
get_current_xray_core_version() {
    XRAY_BINARY="$DATA_MAIN_DIR/xray-core/xray"
    if [ -f "$XRAY_BINARY" ]; then
        "$XRAY_BINARY" -version 2>/dev/null | head -n1 | awk '{print $2}'
        return
    fi
    echo "Not installed"
}

# --- core update ---
get_xray_core() {
    identify_the_operating_system_and_architecture

    latest_releases=$(curl -s "https://api.github.com/repos/${CORE_REPO}/releases?per_page=$LAST_XRAY_CORES")
    versions=($(echo "$latest_releases" | jq -r '.[].tag_name'))

    echo -e "\033[1;32mAvailable Xray-core versions from ${CORE_REPO}:\033[0m"
    for ((i=0; i<${#versions[@]}; i++)); do
        echo "$((i+1)). ${versions[i]}"
    done

    read -p "Choose version [1-${#versions[@]}] or enter manually: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        selected_version="${versions[$((choice-1))]}"
    else
        selected_version="$choice"
    fi

    colorized_echo blue "Selected version: $selected_version"

    mkdir -p "$DATA_MAIN_DIR/xray-core"
    cd "$DATA_MAIN_DIR/xray-core"

    assets_json=$(curl -s "https://api.github.com/repos/${CORE_REPO}/releases/tags/${selected_version}")

    zip_name="Xray-linux-$ARCH.zip"
    tgz_name="Xray-linux-$ARCH.tar.gz"

    xray_download_url=$(echo "$assets_json" | jq -r --arg z "$zip_name" --arg t "$tgz_name" '
      (.assets[]? | select(.name==$t) | .browser_download_url) // 
      (.assets[]? | select(.name==$z) | .browser_download_url) // empty
    ')

    if [ -z "$xray_download_url" ]; then
        colorized_echo red "No asset found for linux-$ARCH"
        exit 1
    fi

    curl -fL --retry 3 -o xray_pkg "$xray_download_url"
    if [[ "$xray_download_url" =~ \.tar\.gz$ ]]; then
        tar -xzf xray_pkg
    else
        unzip -o xray_pkg >/dev/null 2>&1
    fi
    rm -f xray_pkg
}

update_core_command() {
    check_running_as_root
    get_xray_core
    if ! command -v yq >/dev/null 2>&1; then
        install_package yq
    fi
    yq eval '.services."marzban-node".environment.XRAY_EXECUTABLE_PATH = "/var/lib/marzban-node/xray-core/xray"' -i "$COMPOSE_FILE"
    yq eval ".services.\"marzban-node\".volumes += \"${DATA_MAIN_DIR}:/var/lib/marzban-node\"" -i "$COMPOSE_FILE"
    colorized_echo blue "Restarting container..."
    docker compose -f "$COMPOSE_FILE" -p "$APP_NAME" restart
    colorized_echo green "Updated to GFW-knocker Xray-core."
}

# --- usage/help ---
usage() {
    echo "Usage: $APP_NAME [install|update|core-update|restart|logs|status]"
    current_version=$(get_current_xray_core_version)
    echo "Current Xray-core: $current_version"
}

# --- main dispatcher ---
COMMAND="$1"
case "$COMMAND" in
    core-update) update_core_command ;;
    *) usage ;;
esac
