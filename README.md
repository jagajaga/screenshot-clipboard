# screenshot-clipboard

Make macOS screenshots land **both** as a saved file **and** on your clipboard —
at the same time.

By default, `⌘⇧4` saves a file, and `⌃⌘⇧4` copies to the clipboard, but you have
to choose one. This tiny background agent removes the choice: keep pressing
`⌘⇧4` and every screenshot is instantly on your clipboard too, ready to `⌘V`.

- **Native & tiny** — one small Swift binary, no dependencies, no menu-bar app.
- **Event-driven** — kqueue kernel events fire the instant a screenshot lands; effectively no CPU when idle.
- **Robust** — kqueue events survive sleep/wake (unlike FSEvents streams), and a periodic rescan self-heals anything missed.

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
2. A `launchd` agent (`RunAtLoad` + `KeepAlive`) starts the watcher at login
   and restarts it if it ever exits.
3. The watcher holds a **kqueue** vnode dispatch source on the folder. When a
   new `.png` lands, it puts it on the clipboard via `NSPasteboard`. A periodic
   rescan acts as a fallback for any missed event, bounded by a freshness
   window so it can never overwrite your clipboard with an old file.

```
⌘⇧4  →  file saved to ~/Screenshots  →  kqueue fires instantly
     →  screenshot-clipboard copies the PNG to the clipboard  →  ⌘V anywhere
```

Why this design? Screenshots are written as hidden temp files and renamed into
place when complete (handled: hidden files are ignored, the rename is its own
event). FSEvents streams can go stale after sleep/wake — kqueue is fd-based and
kernel-level, so it doesn't. And `launchd WatchPaths` with a one-shot copier
gets spawn-throttled (copies arrive 10-20s late). A resident kqueue watcher
avoids all three failure modes.

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
- Only a *just-saved* screenshot is copied: the copier ignores any file more
  than ~10s old, so deletes, renames, or other folder churn never re-copy an
  old image.

## License

[MIT](LICENSE)
