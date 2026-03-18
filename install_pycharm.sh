#!/bin/sh

set -eu

INSTALL_DIR="/opt/pycharm"
BIN_LINK="/usr/local/bin/pycharm"
DESKTOP_FILE="$HOME/.local/share/applications/pycharm.desktop"
TMP_DIR="$(mktemp -d)"

GITHUB_REPO="JetBrains/intellij-community"
GITHUB_RELEASES_API="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100"

# Fallback URLs if GitHub API parsing fails
FALLBACK_X86_URL="https://download.jetbrains.com/python/pycharm-2025.3.3.tar.gz"
FALLBACK_ARM_URL="https://download.jetbrains.com/python/pycharm-2025.3.3-aarch64.tar.gz"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

log() {
    printf '%s\n' "$1"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required command not found: $1" >&2
        exit 1
    }
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
            echo "Unsupported architecture: $ARCH" >&2
            exit 1
            ;;
    esac
}

extract_version_from_url() {
    printf '%s' "$1" | sed -nE 's#.*pycharm-([0-9]{4}\.[0-9]+\.[0-9]+(\.[0-9]+)?)(-aarch64)?\.tar\.gz#\1#p'
}

version_gt() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ] && [ "$1" != "$2" ]
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

download_and_install() {
    URL="$1"
    ARCHIVE="$TMP_DIR/pycharm.tar.gz"
    EXTRACT_DIR="$TMP_DIR/extracted"

    log "Downloading:"
    log "$URL"
    curl -fL "$URL" -o "$ARCHIVE"

    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"

    EXTRACTED_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

    if [ -z "$EXTRACTED_DIR" ]; then
        echo "Failed to detect extracted PyCharm directory." >&2
        exit 1
    fi

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
}

main() {
    need_cmd uname
    need_cmd sudo
    need_cmd curl
    need_cmd jq
    need_cmd tar
    need_cmd sort
    need_cmd find
    need_cmd head
    need_cmd sed
    need_cmd mktemp

    detect_arch
    install_deps

    DEFAULT_VERSION="$(extract_version_from_url "$FALLBACK_URL")"
    FINAL_URL="$FALLBACK_URL"
    FINAL_VERSION="$DEFAULT_VERSION"

    log "Detected architecture: $ARCH"
    log "Fallback version: $DEFAULT_VERSION"

    LATEST_URL="$(get_latest_pycharm_asset_url || true)"

    if [ -n "$LATEST_URL" ]; then
        LATEST_VERSION="$(extract_version_from_url "$LATEST_URL")"

        if [ -n "$LATEST_VERSION" ]; then
            FINAL_URL="$LATEST_URL"
            FINAL_VERSION="$LATEST_VERSION"
            log "Found latest PyCharm release on GitHub: $FINAL_VERSION"
        else
            log "Failed to parse version from GitHub asset URL. Using fallback."
        fi
    else
        log "Could not detect latest PyCharm release from GitHub. Using fallback."
    fi

    download_and_install "$FINAL_URL"

    log "Installed PyCharm version: $FINAL_VERSION"
    log "Run it with: pycharm"
}

main "$@"
