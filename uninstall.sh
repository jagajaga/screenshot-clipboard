#!/usr/bin/env bash
# Unload and remove the screenshot-clipboard launch agent.
# Leaves your screenshots and the macOS save-location setting untouched.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.screenshotclipboard"
LINK="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "› Unloading agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo "› Removing launch agent link"
rm -f "$LINK"
rm -f "$REPO_DIR/$LABEL.plist"

echo "✓ Uninstalled. (Screenshots and save-location setting left as-is.)"
echo "  To also restore the default save location: defaults write com.apple.screencapture location \"\$HOME/Desktop\""
