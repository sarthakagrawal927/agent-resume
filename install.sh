#!/bin/bash
# install.sh — Install agent-resume
# Usage: curl -fsSL https://raw.githubusercontent.com/sarthakagrawal927/agent-resume/main/install.sh | bash

set -euo pipefail

REPO="sarthakagrawal927/agent-resume"
INSTALL_DIR="/usr/local/bin"
BIN_NAME="agent-resume"

echo "Installing agent-resume..."

# Download the script
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/agent-resume.sh" -o "/tmp/$BIN_NAME"
chmod +x "/tmp/$BIN_NAME"

# Install (may need sudo)
if [ -w "$INSTALL_DIR" ]; then
  mv "/tmp/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
else
  echo "Need sudo to install to $INSTALL_DIR"
  sudo mv "/tmp/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
fi

# Optional: download tiers.json alongside the script
SCRIPT_REAL=$(readlink -f "$INSTALL_DIR/$BIN_NAME" 2>/dev/null || echo "$INSTALL_DIR/$BIN_NAME")
SCRIPT_DIR=$(dirname "$SCRIPT_REAL")
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/tiers.json" -o "$SCRIPT_DIR/tiers.json" 2>/dev/null || true

echo ""
echo "Installed: $(agent-resume --version)"
echo "Run: agent-resume -c"
