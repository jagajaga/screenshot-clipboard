# screenshot-clipboard

Make macOS screenshots land **both** as a saved file **and** on your clipboard —
at the same time.

By default, `⌘⇧4` saves a file, and `⌃⌘⇧4` copies to the clipboard, but you have
to choose one. This tiny background agent removes the choice: keep pressing
`⌘⇧4` and every screenshot is instantly on your clipboard too, ready to `⌘V`.

- **Native & tiny** — one small Swift binary, no dependencies, no menu-bar app.
- **Event-driven** — uses FSEvents; zero polling, effectively no CPU when idle.
- **Starts at login** — a `launchd` agent keeps it running and restarts it if it ever exits.

## Requirements

- macOS
- Xcode Command Line Tools (for `swiftc`): `xcode-select --install`

## Install

```sh
git clone https://github.com/jagajaga/screenshot-clipboard.git
cd screenshot-clipboard
./install.sh
```

The installer builds the binary, creates `~/Screenshots`, points macOS screenshot
saving there, and loads the launch agent. Then just take a screenshot (`⌘⇧4`) and
paste (`⌘V`) to confirm.

Want a different folder?

```sh
SCREENSHOT_DIR="$HOME/Pictures/Shots" ./install.sh
```

## Uninstall

```sh
./uninstall.sh
```

Your screenshots are left in place. The macOS save-location setting is left as-is;
the script prints the one-liner to restore the default (`~/Desktop`) if you want it.

## How it works

1. macOS saves screenshots to a folder (`defaults read com.apple.screencapture location`).
2. A `launchd` agent (`RunAtLoad` + `KeepAlive`) runs the `screenshot-clipboard`
   binary at login and keeps it alive.
3. The binary watches that folder via **FSEvents**. When a new `.png` appears it
   reads the file and puts it on the clipboard via `NSPasteboard`.

```
⌘⇧4  →  file saved to ~/Screenshots  →  FSEvents fires
     →  screenshot-clipboard copies the PNG to the clipboard  →  ⌘V anywhere
```

The launch agent lives in the repo; the installer symlinks it into
`~/Library/LaunchAgents/` (the only place `launchd` auto-loads user agents from).

### Why not keep screenshots on the Desktop?

`~/Desktop`, `~/Documents`, and `~/Downloads` are TCC-protected. A background
agent reading them needs **Full Disk Access**, and that grant is unreliable for
an unsigned command-line binary — it can apply and then silently stop. Saving to
a non-protected folder like `~/Screenshots` sidesteps the whole problem: no
permissions, no fragility.

## Manage

```sh
# is it running?
pgrep -fl screenshot-clipboard

# reload after editing the agent
launchctl bootout   gui/$(id -u)/com.screenshotclipboard
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.screenshotclipboard.plist

# rebuild after editing the source
swiftc -O screenshot-clipboard.swift -o screenshot-clipboard
```

## Notes

- Handles PNG, the macOS default screenshot format. If you've switched formats
  (`defaults write com.apple.screencapture type jpg`), adjust the extension check
  in `screenshot-clipboard.swift`.
- Only screenshots taken *after* the agent starts are copied; it never re-copies
  older files in the folder.

## License

[MIT](LICENSE)
