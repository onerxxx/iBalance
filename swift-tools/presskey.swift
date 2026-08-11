import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: \(args[0]) <virtualKey> [modifiers]\n  Virtual keys: Esc=53, Return=36, Enter=76, Tab=48\n  Modifiers: cmd|shift|alt|ctrl (comma-separated, optional)\n", stderr)
    exit(1)
}

let keyCode = CGKeyCode(UInt32(args[1]) ?? 53)
var flags: CGEventFlags = []
if args.count >= 3 {
    let mods = args[2].lowercased().components(separatedBy: ",")
    if mods.contains("cmd") { flags.insert(.maskCommand) }
    if mods.contains("shift") { flags.insert(.maskShift) }
    if mods.contains("alt") { flags.insert(.maskAlternate) }
    if mods.contains("ctrl") { flags.insert(.maskControl) }
}

let src = CGEventSource(stateID: .combinedSessionState)
if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
    down.flags = flags
    down.post(tap: .cghidEventTap)
}
usleep(20000)
if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
    up.flags = flags
    up.post(tap: .cghidEventTap)
}
