import AppKit
import Foundation

// screenshot-clipboard
// ---------------------
// Copies the most recently saved PNG screenshot to the clipboard, so a macOS
// screenshot (⌘⇧4) becomes both a saved file AND a clipboard image.
//
// One-shot: launchd runs it (via the bundled `WatchPaths` agent) every time the
// screenshot folder changes, and it exits after copying. Keeping it short-lived
// means there is no resident process to go sleep-stale or be App-Napped.
//
// Two subtleties this handles:
//   * launchd fires the moment the folder starts changing — often BEFORE macOS
//     has finished writing the new file — so we briefly wait for it to appear
//     rather than grabbing whatever was newest at that instant (the previous
//     screenshot).
//   * We remember the last file we copied (in a small state file) and only ever
//     copy something strictly newer, so a screenshot is never copied twice and
//     the "one before the last" is never picked.
//
// Usage:  screenshot-clipboard [watch-directory]
// Default watch directory: ~/Screenshots

let dir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (NSHomeDirectory() as NSString).appendingPathComponent("Screenshots")

let fm = FileManager.default
let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches")
let stateFile = (stateDir as NSString).appendingPathComponent("com.screenshotclipboard.last")

func newestPNG() -> (path: String, date: Date)? {
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    var best: (String, Date)?
    for name in entries where name.lowercased().hasSuffix(".png") {
        let p = (dir as NSString).appendingPathComponent(name)
        guard let a = try? fm.attributesOfItem(atPath: p),
              let d = a[.modificationDate] as? Date else { continue }
        if best == nil || d > best!.1 { best = (p, d) }
    }
    return best.map { (path: $0.0, date: $0.1) }
}

// Timestamp (seconds since reference date) of the screenshot we last copied.
let lastCopied = (try? String(contentsOfFile: stateFile, encoding: .utf8))
    .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    ?? -Double.greatestFiniteMagnitude

// Wait (up to ~2s) for a PNG that is newer than the last one we copied and was
// created just now — i.e. the screenshot that triggered this run, once it has
// actually landed on disk.
var target: (path: String, date: Date)?
var waited = 0.0
while waited <= 2.0 {
    if let n = newestPNG(),
       n.date.timeIntervalSinceReferenceDate > lastCopied,
       Date().timeIntervalSince(n.date) < 15 {
        target = n
        break
    }
    usleep(120_000)   // 120 ms
    waited += 0.12
}

guard let hit = target, let data = fm.contents(atPath: hit.path) else { exit(0) }

let pb = NSPasteboard.general
pb.clearContents()
pb.setData(data, forType: .png)

// Record what we copied so the next run copies only something newer.
try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
try? String(hit.date.timeIntervalSinceReferenceDate)
    .write(toFile: stateFile, atomically: true, encoding: .utf8)
