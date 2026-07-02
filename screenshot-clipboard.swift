import AppKit
import Foundation

// screenshot-clipboard
// ---------------------
// Copies the most recently saved PNG screenshot to the clipboard, so a macOS
// screenshot (⌘⇧4) becomes both a saved file AND a clipboard image.
//
// This is a one-shot program: it runs, copies, and exits. It is meant to be
// launched by launchd every time the screenshot folder changes (see the
// bundled launch agent, which uses `WatchPaths`). Keeping it short-lived means
// there is no resident process to be suspended, sleep-stale, or App-Napped —
// launchd does the watching and spawns a fresh copier per screenshot.
//
// Usage:  screenshot-clipboard [watch-directory]
// Default watch directory: ~/Screenshots

let dir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (NSHomeDirectory() as NSString).appendingPathComponent("Screenshots")

let fm = FileManager.default
guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { exit(0) }

// Newest .png in the folder.
var newestPath: String?
var newestDate = Date.distantPast
for name in entries where name.lowercased().hasSuffix(".png") {
    let p = (dir as NSString).appendingPathComponent(name)
    guard let attrs = try? fm.attributesOfItem(atPath: p),
          let mdate = attrs[.modificationDate] as? Date else { continue }
    if mdate > newestDate {
        newestDate = mdate
        newestPath = p
    }
}

guard let path = newestPath else { exit(0) }

// Only act on a just-created screenshot, so folder changes that aren't a new
// screenshot (deletes, renames, .DS_Store churn) don't re-copy an old image.
if Date().timeIntervalSince(newestDate) > 10 { exit(0) }

guard let data = fm.contents(atPath: path) else { exit(0) }
let pb = NSPasteboard.general
pb.clearContents()
pb.setData(data, forType: .png)
