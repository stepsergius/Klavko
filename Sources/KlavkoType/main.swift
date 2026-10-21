// klavko-type: presses physical keys the way a person would, for testing Klavko.
//
//   klavko-type keys en "ghbdsn "      press the keys that type "ghbdsn " in the English layout
//   klavko-type keys uk "руддщ "       press the keys that type "руддщ " in the Ukrainian layout
//   klavko-type tap option,command     press and release modifiers together (a ⌥⌘ chord)
//   klavko-type double rightcommand    the right-hand key (rightshift, rightcontrol, rightoption, rightcommand)
//   klavko-type double shift           tap Shift twice quickly (⇧⇧)
//   klavko-type combo control 47       a key with modifiers, by key code (⌃. here)
//   klavko-type key 51                 one key by key code (51 = Backspace, 36 = Return, 123–126 = arrows)
//   klavko-type layout uk|en           select the keyboard layout
//   klavko-type current                print the current layout's language
//
// KLAVKO_TYPE_DELAY_MS sets the pause between keys (default 60 ms).
// Keys go to the frontmost app. The process running this needs the Accessibility permission.
// Characters are mapped to keys only; the layout that is actually active decides what appears.
import Carbon
import CoreGraphics
import Foundation
import KlavkoCore

let source = CGEventSource(stateID: .hidSystemState)
/// Pause after each key; KLAVKO_TYPE_DELAY_MS=10 imitates very fast typing.
let keyDelay = useconds_t(ProcessInfo.processInfo.environment["KLAVKO_TYPE_DELAY_MS"].flatMap(Int.init) ?? 60) * 1000

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func post(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

func press(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    post(keyCode, down: true, flags: flags)
    post(keyCode, down: false, flags: flags)
    usleep(keyDelay)
}

/// Each modifier with its device-dependent bit, as a real keyboard sends it: that bit tells the left key from the right one.
let modifierKeys: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
    "shift": (56, side(.maskShift, 0x0002)), "control": (59, side(.maskControl, 0x0001)),
    "option": (58, side(.maskAlternate, 0x0020)), "command": (55, side(.maskCommand, 0x0008)),
    "rightshift": (60, side(.maskShift, 0x0004)), "rightcontrol": (62, side(.maskControl, 0x2000)),
    "rightoption": (61, side(.maskAlternate, 0x0040)), "rightcommand": (54, side(.maskCommand, 0x0010)),
]

func side(_ flag: CGEventFlags, _ deviceBit: UInt64) -> CGEventFlags {
    CGEventFlags(rawValue: flag.rawValue | deviceBit)
}

func modifiers(_ list: String) -> [(code: CGKeyCode, flag: CGEventFlags)] {
    list.split(separator: ",").map { name in
        guard let key = modifierKeys[String(name)] else { fail("Unknown modifier \(name): use shift, control, option, command, or rightshift… rightcommand") }
        return key
    }
}

/// Modifiers pressed one after another, then released: what Klavko sees as a modifier tap.
func tapModifiers(_ keys: [(code: CGKeyCode, flag: CGEventFlags)]) {
    var flags: CGEventFlags = []
    for key in keys {
        flags.insert(key.flag)
        flagsChanged(key.code, flags)
        usleep(20_000)
    }
    for key in keys.reversed() {
        flags.remove(key.flag)
        flagsChanged(key.code, flags)
        usleep(20_000)
    }
}

func flagsChanged(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: !flags.isEmpty) else { return }
    event.type = .flagsChanged
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("Usage: see the comment at the top of Sources/KlavkoType/main.swift") }
let layouts = SystemLayouts.enabledLayouts()

switch command {
case "keys":
    guard args.count == 3, let layout = layouts.first(where: { $0.map.language == args[1] })?.map else {
        fail("Usage: klavko-type keys en|uk \"text\"")
    }
    for character in args[2] {
        if character == "\n" { press(36); continue }
        guard let keystroke = layout.keystroke(for: String(character)) else {
            fail("No key for \"\(character)\" in the \(args[1]) layout")
        }
        press(CGKeyCode(keystroke.keyCode), flags: keystroke.shift ? .maskShift : [])
    }
case "tap":
    guard args.count == 2 else { fail("Usage: klavko-type tap option,command") }
    tapModifiers(modifiers(args[1]))
case "double":
    guard args.count == 2 else { fail("Usage: klavko-type double shift") }
    let keys = modifiers(args[1])
    tapModifiers(keys)
    usleep(120_000)
    tapModifiers(keys)
case "combo":
    guard args.count == 3, let code = CGKeyCode(args[2]) else { fail("Usage: klavko-type combo control 47") }
    let keys = modifiers(args[1])
    press(code, flags: keys.reduce(CGEventFlags()) { $0.union($1.flag) })
case "key":
    guard args.count == 2, let code = CGKeyCode(args[1]) else { fail("Usage: klavko-type key 51") }
    press(code)
case "layout":
    guard args.count == 2, let layout = layouts.first(where: { $0.map.language == args[1] }) else {
        fail("Usage: klavko-type layout uk|en")
    }
    SystemLayouts.select(layout.source)
case "current":
    print(SystemLayouts.currentLanguage() ?? "unknown")
default:
    fail("Unknown command \(command)")
}
usleep(100_000)
