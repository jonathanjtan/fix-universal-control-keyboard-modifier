// ucmodswap -- swap option<->command on keyboards arriving over Universal Control.
//
// Universal Control publishes its keyboard as a virtual HID device that never
// appears in the IORegistry, so hidutil and every IOKit-based remapper -- System
// Settings' own "Modifier Keys" panel included -- cannot reach it. macOS saves
// the preference under a stable key and simply never re-applies it when the
// virtual device reconnects.
//
// The events do reach the Quartz event stream, so a CGEventTap can rewrite them.
// The hard part is telling that keyboard from this Mac's own, because a CGEvent
// exposes almost nothing about its origin:
//
//   kCGEventSourceUnixProcessID    0 for both -- UC publishes HID devices rather
//                                  than calling CGEventPost, so its events enter
//                                  through the HID layer like real hardware.
//   kCGKeyboardEventKeyboardType   91 for both, at least on this hardware.
//
// What does work: a CGEvent wraps the IOHIDEvent it came from, and that carries
// the originating service's registry ID. That is per-device and it is the same
// value `hidutil list` prints in its RegistryID column, so it resolves to a
// product name. Universal Control names everything it publishes "V-<original>",
// which makes the rule a name pattern -- stable across reconnects, and narrow
// enough to leave Apple keyboards shared over UC alone, since those already have
// Mac modifier placement.
//
// Modes:
//   ucmodswap            run the tap (default; this is what launchd starts)
//   ucmodswap probe      print every modifier event with its source, for debugging
//   ucmodswap check      report Accessibility trust and exit

import Foundation
import CoreGraphics
import ApplicationServices

// ---------------------------------------------------------------- constants

// CGEventFlags: the two documented modifier bits we swap...
let kMaskCommand:   UInt64 = 0x0010_0000
let kMaskAlternate: UInt64 = 0x0008_0000
// ...and the undocumented-but-stable NX_DEVICE* side bits that ride along with
// them. AppKit uses these to tell left from right; if they are not swapped too,
// apps see a command-flagged event whose side bits say "option" and behave
// inconsistently (Electron apps are especially sensitive to this).
let kDevLCmd: UInt64 = 0x0000_0008
let kDevRCmd: UInt64 = 0x0000_0010
let kDevLAlt: UInt64 = 0x0000_0020
let kDevRAlt: UInt64 = 0x0000_0040

// Carbon virtual keycodes carried by flagsChanged events.
let kKeycodeSwap: [Int64: Int64] = [
    55: 58,  // left command  -> left option
    58: 55,  // left option   -> left command
    54: 61,  // right command -> right option
    61: 54,  // right option  -> right command
]

let kLogPath = NSHomeDirectory() + "/Library/Logs/ucmodswap.log"
let kMaxLogBytes: UInt64 = 1 << 20

// ------------------------------------------------------------------ logging

let gIsTTY = isatty(STDERR_FILENO) == 1

func log(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(msg)\n"
    if gIsTTY { FileHandle.standardError.write(line.data(using: .utf8)!) }
    let fm = FileManager.default
    if let attrs = try? fm.attributesOfItem(atPath: kLogPath),
       let size = attrs[.size] as? UInt64, size > kMaxLogBytes {
        try? fm.removeItem(atPath: kLogPath)
    }
    if !fm.fileExists(atPath: kLogPath) {
        fm.createFile(atPath: kLogPath, contents: nil)
    }
    if let fh = FileHandle(forWritingAtPath: kLogPath) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        try? fh.close()
    }
}

// -------------------------------------------------------- source classifying

// Neither kCGEventSourceUnixProcessID nor kCGKeyboardEventKeyboardType can tell
// Universal Control's keyboard from this Mac's own: UC publishes virtual HID
// devices rather than posting with CGEventPost, so its events enter through the
// HID layer with pid 0, and both keyboards happen to report keyboardType 91.
//
// A CGEvent does wrap the IOHIDEvent it came from, and that carries the
// originating service's registry ID. That is per-device, and it is the same
// value `hidutil list` prints in its RegistryID column -- which lets us resolve
// it to a product name. Universal Control names every device it publishes
// "V-<original name>", so the rule is a name pattern rather than a hard-coded
// id, and survives reconnects.
//
// Both functions are private but long-stable exports; resolved by name so a
// missing symbol degrades to "swap nothing" instead of crashing.

typealias CopyIOHIDEventFn  = @convention(c) (CGEvent) -> Unmanaged<AnyObject>?
typealias GetSenderIDFn     = @convention(c) (AnyObject) -> UInt64

let kRTLDDefault = UnsafeMutableRawPointer(bitPattern: -2)

let gCopyIOHIDEvent: CopyIOHIDEventFn? = dlsym(kRTLDDefault, "CGEventCopyIOHIDEvent")
    .map { unsafeBitCast($0, to: CopyIOHIDEventFn.self) }
let gGetSenderID: GetSenderIDFn? = dlsym(kRTLDDefault, "IOHIDEventGetSenderID")
    .map { unsafeBitCast($0, to: GetSenderIDFn.self) }

func senderID(of event: CGEvent) -> UInt64 {
    guard let copy = gCopyIOHIDEvent, let get = gGetSenderID,
          let unmanaged = copy(event) else { return 0 }
    return get(unmanaged.takeRetainedValue())   // "Copy" -- we own the reference
}

func shell(_ path: String, _ args: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// Returns the `hidutil list` row for a registry id, or nil if it has no row.
func hidutilRow(for sender: UInt64) -> String? {
    let hex = String(format: "0x%llx", sender)
    for line in shell("/usr/bin/hidutil", ["list"]).split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        // VendorID ProductID LocationID UsagePage Usage RegistryID ...
        if fields.count > 6 && fields[5] == hex { return String(line) }
    }
    return nil
}

struct Config {
    // Case-insensitive regex tested against the originating device's row in
    // `hidutil list`. Universal Control publishes everything as "V-<name>".
    var swapPattern: String = " V-"
    // When true, observe and log but change nothing.
    var learnOnly: Bool = false
    // How often to re-read the device list, in seconds.
    var refreshSeconds: Double = 3
}

let kConfigPath = NSHomeDirectory() + "/.config/ucmodswap/config.json"

func loadConfig() -> Config {
    var cfg = Config()
    guard let data = FileManager.default.contents(atPath: kConfigPath) else {
        log("no config at \(kConfigPath); using default pattern \"\(cfg.swapPattern)\"")
        return cfg
    }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        log("config at \(kConfigPath) is not valid JSON; using defaults")
        return cfg
    }
    if let v = obj["swapPattern"] as? String { cfg.swapPattern = v }
    if let v = obj["learnOnly"] as? Bool { cfg.learnOnly = v }
    if let v = obj["refreshSeconds"] as? Double { cfg.refreshSeconds = v }
    log("config: swapPattern=\"\(cfg.swapPattern)\" learnOnly=\(cfg.learnOnly)")
    return cfg
}

// Which senders to swap, refreshed on a background queue.
//
// This deliberately does no work in the event callback beyond a dictionary
// lookup. Shelling out to hidutil per event would add tens of milliseconds to
// every keystroke, and macOS silently disables an event tap whose callback is
// slow to return -- so the table is built off the hot path and only read on it.
//
// Held in a final class rather than a top-level `var`: top-level bindings in a
// Swift script are not reliable shared state when written from a @convention(c)
// callback, which is why an earlier version re-resolved every single keystroke.
final class DeviceTable {
    static let shared = DeviceTable()

    private let lock = NSLock()
    private var verdicts: [UInt64: Bool] = [:]
    private var announced: Set<UInt64> = []
    private let queue = DispatchQueue(label: "ucmodswap.devices")

    func verdict(for sender: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return verdicts[sender] ?? false      // unknown device: leave it alone
    }

    func refreshSoon() { queue.async { self.refresh() } }

    func startPolling(every seconds: Double) {
        queue.async { self.refresh() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        Self.timer = timer
    }
    private static var timer: DispatchSourceTimer?

    private func refresh() {
        let cfg = gConfig
        var fresh: [UInt64: Bool] = [:]
        var rows: [UInt64: String] = [:]
        for line in shell("/usr/bin/hidutil", ["list"]).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // VendorID ProductID LocationID UsagePage Usage RegistryID ...
            guard fields.count > 6, fields[5].hasPrefix("0x"),
                  let id = UInt64(fields[5].dropFirst(2), radix: 16) else { continue }
            let matches = line.range(of: cfg.swapPattern,
                                     options: [.regularExpression, .caseInsensitive]) != nil
            fresh[id] = cfg.learnOnly ? false : matches
            rows[id] = String(line)
        }
        guard !fresh.isEmpty else { return }   // hidutil hiccup: keep what we had

        lock.lock()
        let newlySwapped = fresh.filter { $0.value && !announced.contains($0.key) }
        verdicts = fresh
        announced.formUnion(newlySwapped.keys)
        announced.formIntersection(fresh.keys)   // forget devices that went away
        lock.unlock()

        for (id, _) in newlySwapped {
            log("swapping option<->command on 0x\(String(id, radix: 16)): "
              + (rows[id]?.trimmingCharacters(in: .whitespaces) ?? "?"))
        }
    }
}

var gConfig = Config()

func shouldRemap(_ event: CGEvent) -> Bool {
    DeviceTable.shared.verdict(for: senderID(of: event))
}

// ------------------------------------------------------------------ the swap

func swapFlags(_ flags: UInt64) -> UInt64 {
    var out = flags & ~(kMaskCommand | kMaskAlternate | kDevLCmd | kDevRCmd | kDevLAlt | kDevRAlt)
    if flags & kMaskCommand   != 0 { out |= kMaskAlternate }
    if flags & kMaskAlternate != 0 { out |= kMaskCommand }
    if flags & kDevLCmd != 0 { out |= kDevLAlt }
    if flags & kDevRCmd != 0 { out |= kDevRAlt }
    if flags & kDevLAlt != 0 { out |= kDevLCmd }
    if flags & kDevRAlt != 0 { out |= kDevRCmd }
    return out
}

var gTap: CFMachPort?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    // macOS disables a tap that blocks for too long; re-arm instead of dying.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("tap disabled by system (\(type.rawValue)), re-enabling")
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    guard shouldRemap(event) else { return Unmanaged.passUnretained(event) }

    event.flags = CGEventFlags(rawValue: swapFlags(event.flags.rawValue))
    if type == .flagsChanged {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if let swapped = kKeycodeSwap[code] {
            event.setIntegerValueField(.keyboardEventKeycode, value: swapped)
        }
    }
    return Unmanaged.passUnretained(event)
}

// ------------------------------------------------------------------- probing

let probeCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let kind = type == .flagsChanged ? "flagsChanged" : (type == .keyDown ? "keyDown" : "keyUp")
    let sender = senderID(of: event)
    let row = hidutilRow(for: sender) ?? "(no hidutil row)"
    let note = kKeycodeSwap[code] != nil ? "  <- a modifier we would swap" : ""
    print("\(kind) keycode=\(code) flags=0x\(String(format: "%08llX", event.flags.rawValue)) "
        + "sender=0x\(String(format: "%llx", sender))\n    \(row)\(note)")
    fflush(stdout)
    return Unmanaged.passUnretained(event)
}

// -------------------------------------------------------------------- driver

func requireTrust(prompting: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
    return AXIsProcessTrustedWithOptions([key: prompting] as CFDictionary)
}

func startTap(callback: @escaping CGEventTapCallBack) -> Bool {
    let mask = (1 << CGEventType.flagsChanged.rawValue)
             | (1 << CGEventType.keyDown.rawValue)
             | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: nil) else { return false }
    gTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "daemon"

switch mode {
case "check":
    let trusted = requireTrust(prompting: false)
    print("Accessibility trust: \(trusted ? "granted" : "NOT granted")")
    print("binary: \(CommandLine.arguments[0])")
    if !trusted {
        print("Grant it in System Settings > Privacy & Security > Accessibility,")
        print("then restart the agent:  launchctl kickstart -k gui/$(id -u)/local.ucmodswap")
    }
    exit(trusted ? 0 : 1)

case "probe":
    if !requireTrust(prompting: true) {
        print("Accessibility permission is needed to read events.")
        print("Approve the dialog, then switch ucmodswap on in")
        print("System Settings > Privacy & Security > Accessibility. Waiting...")
        while !requireTrust(prompting: false) { sleep(2) }
        print("granted.\n")
    }
    print("Press modifier keys on BOTH keyboards. Ctrl-C to stop.\n")
    guard startTap(callback: probeCallback) else {
        print("could not create event tap"); exit(1)
    }
    CFRunLoopRun()

default:
    // launchd starts us at login, which can be before the window server is
    // ready to hand out taps, and before the user has granted Accessibility.
    // Wait rather than exiting, so KeepAlive does not spin.
    // AXIsProcessTrustedWithOptions caches its answer for the life of the
    // process, so a run that starts untrusted stays untrusted even after the
    // user flips the switch. Polling in-process therefore never succeeds --
    // exit instead and let launchd's KeepAlive start a fresh one that asks
    // again. ThrottleInterval in the plist keeps that to a slow retry.
    if !requireTrust(prompting: false) {
        // Prompt on the first run only; once per respawn would mean a dialog
        // every few seconds until the user gets to it.
        let marker = NSHomeDirectory() + "/.local/state/ucmodswap/prompted"
        if !FileManager.default.fileExists(atPath: marker) {
            try? FileManager.default.createDirectory(
                atPath: (marker as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker, contents: nil)
            _ = requireTrust(prompting: true)
            log("waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
        }
        sleep(5)
        exit(1)
    }
    gConfig = loadConfig()
    DeviceTable.shared.startPolling(every: gConfig.refreshSeconds)
    guard startTap(callback: tapCallback) else {
        log("could not create event tap; exiting so launchd retries")
        exit(1)
    }
    // Re-read the rule without a rebuild: rebuilding changes the code signature
    // and can cost the Accessibility grant.
    signal(SIGHUP, SIG_IGN)
    let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
    hup.setEventHandler { gConfig = loadConfig(); DeviceTable.shared.refreshSoon(); log("config reloaded") }
    hup.resume()
    log("ucmodswap running")
    signal(SIGTERM) { _ in log("terminating"); exit(0) }
    CFRunLoopRun()
    log("run loop exited unexpectedly")
    exit(1)
}
