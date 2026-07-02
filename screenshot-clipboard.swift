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
// Design notes, learned the hard way:
//   * modern macOS composes the screenshot elsewhere and moves it into the
//     folder ATOMICALLY — the file appears complete in a single event. So we
//     validate completeness via the PNG's own end marker (IEND trailer)
//     instead of sleeping and re-checking sizes.
//   * stat-ing every file in a large folder on each event costs ~0.5-2s;
//     being resident, we remember the folder's name-set and stat only names
//     we haven't seen before.
//   * launchd WatchPaths + a one-shot copier gets spawn-throttled (10-22s
//     late); FSEvents streams go stale after sleep. Hence resident + kqueue.
//   * hidden dotfiles (old-style ".Screenshot ….png" temps) are ignored.
//   * only a file strictly newer than the last one copied is taken, and only
//     if freshly created — never a re-copy, and the rescan fallback can never
//     clobber the clipboard with something old.
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

// Visible .png names only — a single directory read, no per-file stats.
func listPNGs() -> [String]? {
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    return entries.filter { $0.lowercased().hasSuffix(".png") && !$0.hasPrefix(".") }
}

func mtime(_ name: String) -> Date? {
    let p = (dir as NSString).appendingPathComponent(name)
    return (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date
}

// Complete PNG = magic header at the front, IEND chunk trailer at the end.
let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
let pngTrailer = Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
func isCompletePNG(_ d: Data) -> Bool {
    d.count > 24 && d.prefix(8) == pngMagic && d.suffix(8) == pngTrailer
}

// --- state -------------------------------------------------------------
// Names present at baseline or already handled; stat only what's new.
// (Screenshots always get fresh names, so overwrites-in-place are ignored.)
var knownNames: Set<String>

// Timestamp (seconds since reference date) of the last screenshot copied.
// Baseline on both the persisted state and whatever already exists, so
// neither a restart nor pre-existing files cause a copy of something old.
var lastCopied: Double

let persisted = (try? String(contentsOfFile: stateFile, encoding: .utf8))
    .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    ?? -Double.greatestFiniteMagnitude
let baselineNames = listPNGs() ?? []
knownNames = Set(baselineNames)
// One full stat pass, at startup only.
let newestExisting = baselineNames.compactMap { mtime($0) }.max()
lastCopied = max(persisted,
                 newestExisting?.timeIntervalSinceReferenceDate ?? -Double.greatestFiniteMagnitude)

func handleChange() {
    guard let names = listPNGs() else { return }
    let fresh = names.filter { !knownNames.contains($0) }
    knownNames = Set(names)
    guard !fresh.isEmpty else { return }

    // Stat only the new arrivals, take the newest.
    var best: (name: String, date: Date)?
    for n in fresh {
        guard let d = mtime(n) else { continue }
        if best == nil || d > best!.date { best = (n, d) }
    }
    guard let hit = best else { return }
    let age = Date().timeIntervalSince(hit.date)
    guard hit.date.timeIntervalSinceReferenceDate > lastCopied, age < FRESH_WINDOW else { return }

    let path = (dir as NSString).appendingPathComponent(hit.name)

    // The file normally lands complete (atomic move); validate via the PNG
    // trailer and retry briefly in case some tool writes it in place.
    var copied = false
    for _ in 0..<20 {
        if let data = fm.contents(atPath: path), isCompletePNG(data) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
            copied = true
            break
        }
        usleep(100_000)   // 100 ms, up to ~2s total
    }
    guard copied else { return }

    // Record the newest mtime (a slow in-place writer may have bumped it).
    let finalDate = mtime(hit.name) ?? hit.date
    lastCopied = max(finalDate, hit.date).timeIntervalSinceReferenceDate
    try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    try? String(lastCopied).write(toFile: stateFile, atomically: true, encoding: .utf8)
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
        queue.asyncAfter(deadline: .now() + 5) { startWatch() }
        return
    }
    let src = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
    src.setEventHandler {
        let ev = src.data
        if ev.contains(.delete) || ev.contains(.rename) {
            src.cancel()   // cancel handler closes fd and rearms
        } else {
            handleChange()
        }
    }
    src.setCancelHandler {
        close(fd)
        queue.asyncAfter(deadline: .now() + 1) { startWatch() }
    }
    src.resume()
    watchSource = src
}

startWatch()

// Fallback rescan: catches anything a kqueue event might have missed.
let rescan = DispatchSource.makeTimerSource(queue: queue)
rescan.schedule(deadline: .now() + RESCAN_SECONDS, repeating: RESCAN_SECONDS)
rescan.setEventHandler { handleChange() }
rescan.resume()

_ = activity
dispatchMain()
