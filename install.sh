#!/usr/bin/env bash
# One-shot install from GitHub: copy scripts to ~/network-split-tunnel and apply.
set -euo pipefail

REPO_TARBALL="https://codeload.github.com/mojtba-allam/Network-tunneling/tar.gz/refs/heads/main"

if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  USER_HOME="${HOME}"
fi
DEST="${INSTALL_DIR:-$USER_HOME/network-split-tunnel}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Network-tunneling (main)..."
curl -fsSL "$REPO_TARBALL" | tar -xz -C "$tmp"
src="$(find "$tmp" -maxdepth 2 -type d -name network-split-tunnel | head -1)"
[[ -n "$src" ]] || { echo "ERROR: archive missing network-split-tunnel/"; exit 1; }

mkdir -p "$DEST"
cp -a "$src"/. "$DEST/"
chmod +x "$DEST/network-split-tunnel.sh" "$DEST/rollback.sh" "$DEST/templates/50-split-direct"

echo "Installed to $DEST"
echo "Taking a backup, then applying split tunnel (sudo)..."
SPLIT_TUNNEL_CONFIRM=yes "$DEST/network-split-tunnel.sh" apply

echo
echo "Done. Test: $DEST/network-split-tunnel.sh test"
echo "Undo:  sudo $DEST/rollback.sh"
