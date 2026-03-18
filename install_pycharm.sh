#!/bin/sh

# Run on Linux in one line:
# curl -fsSL https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/install_pycharm.sh -o /tmp/install_pycharm.sh && sh /tmp/install_pycharm.sh

set -eu

INSTALL_DIR="/opt/pycharm"
BIN_LINK="/usr/local/bin/pycharm"
DESKTOP_FILE="$HOME/.local/share/applications/pycharm.desktop"
TMP_DIR="$(mktemp -d)"

GITHUB_REPO="JetBrains/intellij-community"
GITHUB_RELEASES_API="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100"

# Fallback URLs
FALLBACK_X86_URL="https://download.jetbrains.com/python/pycharm-2025.3.3.tar.gz"
FALLBACK_ARM_URL="https://download.jetbrains.com/python/pycharm-2025.3.3-aarch64.tar.gz"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

log() {
    printf '%s\n' "$1"
}

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

check_supported_os() {
    OS_NAME="$(uname -s)"

    [ "$OS_NAME" = "Linux" ] || fail "This script supports Linux only. Detected: $OS_NAME"

    [ -f /etc/os-release ] || fail "/etc/os-release not found. Unsupported Linux distribution."

    # shellcheck disable=SC1091
    . /etc/os-release

    DIST_ID="${ID:-}"
    DIST_LIKE="${ID_LIKE:-}"

    case "$DIST_ID" in
        ubuntu|xubuntu|linuxmint|pop|elementary|zorin|neon|debian)
            ;;
        *)
            case " $DIST_LIKE " in
                *" ubuntu "*|*" debian "*)
                    ;;
                *)
                    fail "Unsupported distribution: ID=${DIST_ID:-unknown}, ID_LIKE=${DIST_LIKE:-unknown}. Supported: Ubuntu/Xubuntu or Debian-based systems with apt."
                    ;;
            esac
            ;;
    esac

    command -v apt >/dev/null 2>&1 || fail "apt not found. This script requires an apt-based system."
    command -v sudo >/dev/null 2>&1 || fail "sudo not found."
}

detect_arch() {
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)
            PYCHARM_ARCH="x86_64"
            FALLBACK_URL="$FALLBACK_X86_URL"
            ;;
        aarch64|arm64)
            PYCHARM_ARCH="aarch64"
            FALLBACK_URL="$FALLBACK_ARM_URL"
            ;;
        *)
            fail "Unsupported architecture: $ARCH"
            ;;
    esac
}

extract_version_from_url() {
    printf '%s' "$1" | sed -nE 's#.*pycharm-([0-9]{4}\.[0-9]+\.[0-9]+(\.[0-9]+)?)(-aarch64)?\.tar\.gz#\1#p'
}

get_installed_version() {
    if [ -f "$INSTALL_DIR/product-info.json" ]; then
        jq -r '.version // empty' "$INSTALL_DIR/product-info.json" 2>/dev/null || true
        return
    fi

    if [ -f "$INSTALL_DIR/build.txt" ]; then
        cat "$INSTALL_DIR/build.txt" 2>/dev/null || true
        return
    fi

    printf ''
}

is_installed() {
    [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/bin/pycharm" ]
}

install_deps() {
    log "Installing required packages..."
    sudo apt update
    sudo apt install -y curl jq tar
}

get_latest_pycharm_asset_url() {
    API_JSON="$TMP_DIR/releases.json"

    curl -fsSL "$GITHUB_RELEASES_API" -o "$API_JSON"

    if [ "$PYCHARM_ARCH" = "aarch64" ]; then
        jq -r '
            [
              .[]
              | select(.tag_name | startswith("pycharm/"))
              | .assets[]
              | select(.name | test("^pycharm-[0-9]{4}\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?-aarch64\\.tar\\.gz$"))
              | {url: .browser_download_url, name: .name}
            ]
            | sort_by(.name)
            | last
            | .url // empty
        ' "$API_JSON"
    else
        jq -r '
            [
              .[]
              | select(.tag_name | startswith("pycharm/"))
              | .assets[]
              | select(.name | test("^pycharm-[0-9]{4}\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?\\.tar\\.gz$"))
              | select(.name | contains("-aarch64") | not)
              | {url: .browser_download_url, name: .name}
            ]
            | sort_by(.name)
            | last
            | .url // empty
        ' "$API_JSON"
    fi
}

resolve_download_url() {
    LATEST_URL="$(get_latest_pycharm_asset_url || true)"

    if [ -n "$LATEST_URL" ]; then
        printf '%s\n' "$LATEST_URL"
    else
        printf '%s\n' "$FALLBACK_URL"
    fi
}

download_and_install() {
    URL="$1"
    VERSION="$(extract_version_from_url "$URL")"
    ARCHIVE="$TMP_DIR/pycharm.tar.gz"
    EXTRACT_DIR="$TMP_DIR/extracted"

    log "Downloading:"
    log "$URL"
    curl -fL "$URL" -o "$ARCHIVE"

    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"

    EXTRACTED_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

    [ -n "$EXTRACTED_DIR" ] || fail "Failed to detect extracted PyCharm directory."

    log "Installing to $INSTALL_DIR ..."
    sudo rm -rf "$INSTALL_DIR"
    sudo mv "$EXTRACTED_DIR" "$INSTALL_DIR"

    log "Creating binary symlink..."
    sudo ln -sf "$INSTALL_DIR/bin/pycharm" "$BIN_LINK"

    log "Creating desktop entry..."
    mkdir -p "$(dirname "$DESKTOP_FILE")"

    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=PyCharm
Exec=$INSTALL_DIR/bin/pycharm %f
Icon=$INSTALL_DIR/bin/pycharm.png
Comment=JetBrains PyCharm
Categories=Development;IDE;
Terminal=false
StartupWMClass=jetbrains-pycharm
StartupNotify=true
EOF

    chmod +x "$DESKTOP_FILE"

    log "Installed PyCharm version: ${VERSION:-unknown}"
    log "Run it with: pycharm"
}

do_install() {
    URL="$(resolve_download_url)"
    download_and_install "$URL"
}

do_update() {
    if ! is_installed; then
        log "PyCharm is not installed in $INSTALL_DIR"
        log "Starting install instead..."
        do_install
        return
    fi

    INSTALLED_VERSION="$(get_installed_version)"
    LATEST_URL="$(resolve_download_url)"
    LATEST_VERSION="$(extract_version_from_url "$LATEST_URL")"

    log "Installed version: ${INSTALLED_VERSION:-unknown}"
    log "Latest available version: ${LATEST_VERSION:-unknown}"

    if [ -n "$INSTALLED_VERSION" ] && [ -n "$LATEST_VERSION" ] && [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
        log "PyCharm is already up to date."
        exit 0
    fi

    download_and_install "$LATEST_URL"
}

do_uninstall() {
    if ! is_installed; then
        log "PyCharm is not installed in $INSTALL_DIR"
        exit 0
    fi

    log "Removing installation..."
    sudo rm -rf "$INSTALL_DIR"

    if [ -L "$BIN_LINK" ] || [ -f "$BIN_LINK" ]; then
        sudo rm -f "$BIN_LINK"
    fi

    if [ -f "$DESKTOP_FILE" ]; then
        rm -f "$DESKTOP_FILE"
    fi

    log "PyCharm uninstalled."
}

show_menu_for_installed() {
    INSTALLED_VERSION="$(get_installed_version)"
    printf '\n'
    printf 'PyCharm is already installed'
    if [ -n "$INSTALLED_VERSION" ]; then
        printf ' (version: %s)' "$INSTALLED_VERSION"
    fi
    printf '.\n'
    printf 'Choose action:\n'
    printf '1) update\n'
    printf '2) uninstall\n'
    printf '> '
    read -r CHOICE

    case "$CHOICE" in
        1|update|u)
            do_update
            ;;
        2|uninstall|remove|delete)
            do_uninstall
            ;;
        *)
            fail "Unknown choice: $CHOICE"
            ;;
    esac
}

main() {
    need_cmd uname
    need_cmd find
    need_cmd head
    need_cmd sed
    need_cmd mktemp

    check_supported_os
    detect_arch
    install_deps

    if is_installed; then
        show_menu_for_installed
    else
        log "PyCharm is not installed in $INSTALL_DIR"
        log "Starting install..."
        do_install
    fi
}

main "$@"
