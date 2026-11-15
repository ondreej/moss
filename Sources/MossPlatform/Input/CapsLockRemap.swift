import Foundation
import IOKit.hid
import IOKit.hidsystem
import os
import MossRuntime

/// One entry of the system's `UserKeyMapping` list. Both sides are HID usages packed as
/// `page << 32 | usage`, the form `hidutil` takes.
struct HIDKeyMapping: Hashable, Sendable {
    let source: UInt64
    let destination: UInt64
}

/// Turns Caps Lock into a key the event tap can see. Caps Lock is a lock toggled in the
/// keyboard driver and never reaches the tap, so it is remapped to F18, which does, and the
/// tap treats F18 as the `caps` modifier or as Hyper.
///
/// The mapping list is shared by the whole system and may hold the user's own mappings, so
/// only Moss's entry is ever added or removed; a mapping of Caps Lock it replaced is
/// remembered and put back.
enum CapsLockRemap {
    static let capsLock: UInt64 = 0x7_0000_0039
    static let f18: UInt64 = 0x7_0000_006D
    /// The virtual key code F18 arrives with.
    static let f18KeyCode: UInt16 = 79
    static let entry = HIDKeyMapping(source: capsLock, destination: f18)

    private static let replacedKey = "ReplacedCapsLockMapping"

    // MARK: Merging

    /// `list` with Caps Lock mapped to F18, and the mapping of Caps Lock it replaced, if any.
    static func adding(to list: [HIDKeyMapping]) -> (list: [HIDKeyMapping], replaced: HIDKeyMapping?) {
        let replaced = list.first { $0.source == capsLock && $0 != entry }
        return (list.filter { $0.source != capsLock } + [entry], replaced)
    }

    /// `list` without Moss's entry, with `replaced` put back.
    static func removing(from list: [HIDKeyMapping], restoring replaced: HIDKeyMapping?) -> [HIDKeyMapping] {
        guard list.contains(entry) else { return list }
        return list.filter { $0 != entry } + (replaced.map { [$0] } ?? [])
    }

    // MARK: Applying

    static func apply(_ enabled: Bool) {
        guard let current = read() else {
            Log.input.error("could not read the key mapping list; Caps Lock left unchanged")
            return
        }
        let defaults = UserDefaults.standard
        if enabled {
            let (list, replaced) = adding(to: current)
            guard list != current else { return }
            if let replaced { defaults.set([replaced.source, replaced.destination], forKey: replacedKey) }
            write(list)
        } else {
            let saved = (defaults.array(forKey: replacedKey) as? [UInt64]).flatMap { $0.count == 2 ? HIDKeyMapping(source: $0[0], destination: $0[1]) : nil }
            let list = removing(from: current, restoring: saved)
            guard list != current else { return }
            defaults.removeObject(forKey: replacedKey)
            write(list)
        }
    }

    private static func read() -> [HIDKeyMapping]? {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let value = IOHIDEventSystemClientCopyProperty(client, "UserKeyMapping" as CFString) else { return [] }
        guard let entries = value as? [[String: Any]] else { return nil }
        var result: [HIDKeyMapping] = []
        for entry in entries {
            guard let source = (entry["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value,
                  let destination = (entry["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value else { return nil }
            result.append(HIDKeyMapping(source: source, destination: destination))
        }
        return result
    }

    /// Writes through `hidutil`, which is allowed to change the list.
    private static func write(_ list: [HIDKeyMapping]) {
        let entries = list.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.input.error("hidutil failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Locking capitals

    /// Turns capital locking on or off, as Caps Lock itself does when it is not remapped.
    static func toggleLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connection) }
        var isOn = false
        guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &isOn) == KERN_SUCCESS else { return }
        IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), !isOn)
    }
}
