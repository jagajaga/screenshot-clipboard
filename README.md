# screenshot-clipboard

Make macOS screenshots land **both** as a saved file **and** on your clipboard —
at the same time.

By default, `⌘⇧4` saves a file, and `⌃⌘⇧4` copies to the clipboard, but you have
to choose one. This tiny background agent removes the choice: keep pressing
`⌘⇧4` and every screenshot is instantly on your clipboard too, ready to `⌘V`.

- **Native & tiny** — one small Swift binary, no dependencies, no menu-bar app.
- **Event-driven** — `launchd` triggers it on each new screenshot; no polling, no resident process, no CPU when idle.
- **Robust** — nothing stays running to go stale after sleep/wake; launchd does the watching and spawns a fresh copier per screenshot.

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
2. A `launchd` agent watches that folder with **`WatchPaths`**. It is loaded at
   login and stays armed by launchd itself — no process of ours is kept running.
3. On each change, launchd runs the short-lived `screenshot-clipboard` binary,
   which grabs the just-saved `.png` and puts it on the clipboard via
   `NSPasteboard`, then exits.

```
⌘⇧4  →  file saved to ~/Screenshots  →  launchd WatchPaths fires
     →  screenshot-clipboard runs, copies the PNG, exits  →  ⌘V anywhere
```

Why not a resident FSEvents watcher? A long-lived process that watches the
folder itself works until the Mac sleeps or sits idle — then the event stream
can go stale and silently stop. Letting launchd (which never sleeps) do the
watching and spawn a fresh one-shot per screenshot avoids that entirely.

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
# is the agent loaded? (it runs on demand, so it won't show in `ps`)
launchctl print gui/$(id -u)/com.screenshotclipboard

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
- Only a *just-saved* screenshot is copied: the copier ignores any file more
  than ~10s old, so deletes, renames, or other folder churn never re-copy an
  old image.

## License

[MIT](LICENSE)
