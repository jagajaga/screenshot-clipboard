import AppKit
import Foundation
import CoreServices

// screenshot-clipboard
// ---------------------
// Watches a folder and copies each newly-saved PNG screenshot to the clipboard,
// so a macOS screenshot (⌘⇧4) becomes both a saved file AND a clipboard image.
//
// Usage:  screenshot-clipboard [watch-directory]
// Default watch directory: ~/Screenshots
//
// Runs as a resident process (see the launchd agent) using FSEvents; between
// screenshots it sits idle with no polling.

let dir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (NSHomeDirectory() as NSString).appendingPathComponent("Screenshots")

func newestPNG() -> (path: String, date: Date)? {
    let fm = FileManager.default
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

// Baseline on whatever already exists, so we only copy screenshots taken
// after this process starts — never re-copy an old one.
var lastDate = newestPNG()?.date ?? Date.distantPast

func handleChange() {
    guard let n = newestPNG(), n.date > lastDate else { return }
    lastDate = n.date
    guard let data = FileManager.default.contents(atPath: n.path) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(data, forType: .png)
}

let callback: FSEventStreamCallback = { _, _, _, _, _, _ in handleChange() }

var context = FSEventStreamContext(version: 0, info: nil, retain: nil,
                                   release: nil, copyDescription: nil)
guard let stream = FSEventStreamCreate(
    kCFAllocatorDefault,
    callback,
    &context,
    [dir] as CFArray,
    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
    0.2,
    FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
) else {
    FileHandle.standardError.write(Data("screenshot-clipboard: failed to watch \(dir)\n".utf8))
    exit(1)
}

FSEventStreamSetDispatchQueue(stream, DispatchQueue.global())
FSEventStreamStart(stream)
dispatchMain()
