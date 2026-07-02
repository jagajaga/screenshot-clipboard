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
// Subtleties this handles:
//   * macOS writes a screenshot as a HIDDEN dotfile (".Screenshot ….png") in
//     the same folder and renames it to the visible name only when the write
//     is complete. We ignore hidden files — reading the temp mid-write puts
//     corrupt data on the clipboard.
//   * launchd fires the moment the folder starts changing (the temp file), so
//     we briefly wait for the finished, visible PNG to appear.
//   * We remember the last file we copied (in a small state file) and only
//     ever copy something strictly newer — never a re-copy, never the
//     one-before-last.
//   * Belt and braces: before copying we wait until the file's size is stable,
//     in case some other tool writes PNGs into the folder without the
//     temp-then-rename dance.
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
    for name in entries
    where name.lowercased().hasSuffix(".png") && !name.hasPrefix(".") {
        let p = (dir as NSString).appendingPathComponent(name)
        guard let a = try? fm.attributesOfItem(atPath: p),
              let d = a[.modificationDate] as? Date else { continue }
        if best == nil || d > best!.1 { best = (p, d) }
    }
    return best.map { (path: $0.0, date: $0.1) }
}

func fileSize(_ p: String) -> Int {
    ((try? fm.attributesOfItem(atPath: p))?[.size] as? Int) ?? 0
}

// Timestamp (seconds since reference date) of the screenshot we last copied.
let lastCopied = (try? String(contentsOfFile: stateFile, encoding: .utf8))
    .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    ?? -Double.greatestFiniteMagnitude

// Wait (up to ~4s) for a visible PNG that is newer than the last one we copied
// and was created just now — i.e. the screenshot that triggered this run, once
// macOS has finished writing and renamed it into place. If it takes longer,
// the rename itself re-fires the agent and the next run picks it up.
var target: (path: String, date: Date)?
var waited = 0.0
while waited <= 4.0 {
    if let n = newestPNG(),
       n.date.timeIntervalSinceReferenceDate > lastCopied,
       Date().timeIntervalSince(n.date) < 15 {
        target = n
        break
    }
    usleep(120_000)   // 120 ms
    waited += 0.12
}

guard let hit = target else { exit(0) }

// Don't read until the size stops changing (and is nonzero).
var size = fileSize(hit.path)
var stableWait = 0.0
while stableWait <= 3.0 {
    usleep(150_000)   // 150 ms
    let s2 = fileSize(hit.path)
    if s2 > 0 && s2 == size { break }
    size = s2
    stableWait += 0.15
}

guard let data = fm.contents(atPath: hit.path) else { exit(0) }

let pb = NSPasteboard.general
pb.clearContents()
pb.setData(data, forType: .png)

// Record what we copied so the next run copies only something newer. Re-stat:
// writes during our stability wait may have bumped the mtime past what we saw.
let finalDate = ((try? fm.attributesOfItem(atPath: hit.path))?[.modificationDate] as? Date) ?? hit.date
try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
try? String(max(finalDate, hit.date).timeIntervalSinceReferenceDate)
    .write(toFile: stateFile, atomically: true, encoding: .utf8)
