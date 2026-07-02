import AppKit
import Foundation

// screenshot-clipboard
// ---------------------
// Copies each newly-saved PNG screenshot to the clipboard, so a macOS
// screenshot (⌘⇧4) becomes both a saved file AND a clipboard image.
//
// Resident watcher (launchd keeps it alive, RunAtLoad + KeepAlive). Watches
// the folder with a kqueue vnode dispatch source — kernel-level, fd-based
// events that, unlike FSEvents streams, do not go stale after sleep/wake —
// plus a periodic rescan as a fallback, so a missed event self-heals.
//
// Why not launchd WatchPaths + a one-shot copier? launchd throttles spawns
// (observed 10-22s delays), so the clipboard lagged behind rapid screenshots.
// A resident process reacts instantly.
//
// Subtleties handled:
//   * macOS writes a screenshot as a HIDDEN dotfile (".Screenshot ….png") and
//     renames it to the visible name when complete — hidden files are ignored
//     (reading the temp mid-write yields corrupt data); the rename generates
//     its own kqueue event.
//   * Only a file strictly newer than the last one copied is taken, and only
//     if freshly created — never a re-copy, never an old file, and the rescan
//     fallback can never clobber the clipboard with something stale.
//   * Before reading, wait until the file size is stable, for tools that
//     write PNGs directly without the temp-then-rename dance.
//
// Usage:  screenshot-clipboard [watch-directory]
// Default watch directory: ~/Screenshots

let dir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (NSHomeDirectory() as NSString).appendingPathComponent("Screenshots")

let fm = FileManager.default
let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches")
let stateFile = (stateDir as NSString).appendingPathComponent("com.screenshotclipboard.last")

// Rescan fallback cadence; must be shorter than FRESH_WINDOW or a screenshot
// whose kqueue event was missed would already be "too old" when the rescan
// finds it.
let RESCAN_SECONDS = 10.0
let FRESH_WINDOW = 15.0

// TEMPORARY debug logging: append every decision to /tmp for diagnosis.
let dbgPath = "/tmp/screenshot-clipboard-debug.log"
let dbgClock = ISO8601DateFormatter()
func dbg(_ s: String) {
    let line = "\(dbgClock.string(from: Date())) [\(getpid())] \(s)\n"
    if let h = FileHandle(forWritingAtPath: dbgPath) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
    } else {
        try? line.write(toFile: dbgPath, atomically: false, encoding: .utf8)
    }
}

func newestPNG() -> (path: String, date: Date)? {
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
        dbg("ERROR contentsOfDirectory failed for \(dir)")
        return nil
    }
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

// Timestamp (seconds since reference date) of the last screenshot copied.
// Baseline on both the persisted state and whatever already exists, so neither
// a restart nor pre-existing files ever cause a copy of something old.
let persisted = (try? String(contentsOfFile: stateFile, encoding: .utf8))
    .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    ?? -Double.greatestFiniteMagnitude
var lastCopied = max(persisted, newestPNG()?.date.timeIntervalSinceReferenceDate
    ?? -Double.greatestFiniteMagnitude)

func handleChange(_ origin: String) {
    guard let n = newestPNG() else { return }
    let age = Date().timeIntervalSince(n.date)
    guard n.date.timeIntervalSinceReferenceDate > lastCopied, age < FRESH_WINDOW else { return }
    dbg("[\(origin)] candidate \((n.path as NSString).lastPathComponent) age=\(String(format: "%.1f", age))s")

    // Don't read until the size stops changing (and is nonzero).
    var size = fileSize(n.path)
    var stableWait = 0.0
    while stableWait <= 3.0 {
        usleep(150_000)   // 150 ms
        let s2 = fileSize(n.path)
        if s2 > 0 && s2 == size { break }
        size = s2
        stableWait += 0.15
    }

    guard let data = fm.contents(atPath: n.path) else {
        dbg("EXIT could not read file contents")
        return
    }

    let pb = NSPasteboard.general
    pb.clearContents()
    let ok = pb.setData(data, forType: .png)

    // Writes during the stability wait may have bumped the mtime past what we
    // saw — record the latest so the next event can't mistake it for new.
    let finalDate = ((try? fm.attributesOfItem(atPath: n.path))?[.modificationDate] as? Date) ?? n.date
    lastCopied = max(finalDate, n.date).timeIntervalSinceReferenceDate
    try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    try? String(lastCopied).write(toFile: stateFile, atomically: true, encoding: .utf8)
    dbg("COPIED \(data.count) bytes, setData=\(ok)")
}

// Keep macOS from App-Napping the watcher.
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .automaticTerminationDisabled],
    reason: "watching screenshot folder")

let queue = DispatchQueue(label: "screenshot-clipboard.watch")
var watchSource: DispatchSourceFileSystemObject?

func startWatch() {
    let fd = open(dir, O_EVTONLY)
    guard fd >= 0 else {
        dbg("ERROR open(\(dir)) failed, retrying in 5s")
        queue.asyncAfter(deadline: .now() + 5) { startWatch() }
        return
    }
    let src = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
    src.setEventHandler {
        let ev = src.data
        if ev.contains(.delete) || ev.contains(.rename) {
            dbg("watch dir replaced, rearming")
            src.cancel()   // cancel handler closes fd and rearms
        } else {
            handleChange("kqueue")
        }
    }
    src.setCancelHandler {
        close(fd)
        queue.asyncAfter(deadline: .now() + 1) { startWatch() }
    }
    src.resume()
    watchSource = src
}

dbg("START resident dir=\(dir) baseline=\(lastCopied)")
startWatch()

// Fallback rescan: catches anything a kqueue event might have missed.
let rescan = DispatchSource.makeTimerSource(queue: queue)
rescan.schedule(deadline: .now() + RESCAN_SECONDS, repeating: RESCAN_SECONDS)
rescan.setEventHandler { handleChange("rescan") }
rescan.resume()

_ = activity
dispatchMain()
