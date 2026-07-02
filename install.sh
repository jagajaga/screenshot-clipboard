#!/usr/bin/env bash
# Build and install screenshot-clipboard as a per-user launch agent.
#
#   ./install.sh
#
# Override the watched/save folder (default ~/Screenshots):
#   SCREENSHOT_DIR="$HOME/Pictures/Shots" ./install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.screenshotclipboard"
WATCH_DIR="${SCREENSHOT_DIR:-$HOME/Screenshots}"
BIN="$REPO_DIR/screenshot-clipboard"
PLIST="$REPO_DIR/$LABEL.plist"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LINK="$AGENTS_DIR/$LABEL.plist"

command -v swiftc >/dev/null || { echo "error: swiftc not found (install Xcode Command Line Tools: xcode-select --install)"; exit 1; }

echo "› Building binary…"
swiftc -O "$REPO_DIR/screenshot-clipboard.swift" -o "$BIN"

echo "› Ensuring screenshot folder: $WATCH_DIR"
mkdir -p "$WATCH_DIR"

echo "› Pointing macOS screenshots at that folder"
defaults write com.apple.screencapture location "$WATCH_DIR"

echo "› Generating launch agent from template"
sed -e "s#__BINARY__#$BIN#" -e "s#__WATCH_DIR__#$WATCH_DIR#" \
    "$REPO_DIR/$LABEL.plist.template" > "$PLIST"

echo "› Linking into $AGENTS_DIR"
mkdir -p "$AGENTS_DIR"
ln -sf "$PLIST" "$LINK"

echo "› (Re)loading agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LINK"

echo
echo "✓ Installed. Watching: $WATCH_DIR"
echo "  Take a screenshot (⌘⇧4), then paste (⌘V) to test."
echo "  Status: pgrep -fl screenshot-clipboard"
