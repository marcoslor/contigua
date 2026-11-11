// Control Center and menu bar controls (docs/design/controls.md). A widget
// extension (com.apple.widgetkit-extension) with four controls: phone DND, Ring,
// Ringer and Open Contigua. It never owns the session: it reads the snapshot
// the app writes into the App Group container and sends each action as one JSON
// line over the group socket, where the app runs the same code as the menu bar
// and the App Intents.
//
// Built by macos/scripts/bundle.sh --with-controls with swiftc (SwiftPM cannot
// link an app extension's entry point); ControlsCore.swift is compiled into it
// so both sides share the snapshot and request shapes.

import AppIntents
import Foundation
import SwiftUI
import WidgetKit

// MARK: - Container access

/// The folder the app writes the snapshot and socket into. A sandboxed
/// extension sees the App Group container; without the entitlement this is nil
/// and every control shows its unavailable state.
func controlsDirectory() -> URL? {
    ControlsPaths.groupDirectory()
}

/// One line per perform(): the pid and executable prove which process the
/// system runs a control's intent in (the spike's question), and the request
/// text makes a failed socket obvious. No phone data ever reaches this file.
func controlsLog(_ message: String) {
    NSLog("controls-ext: %@", message)
    guard let directory = controlsDirectory() else { return }
    let line = "\(Date().timeIntervalSince1970) pid=\(getpid()) exe=\(Bundle.main.bundlePath) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = directory.appendingPathComponent("controls-ext.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

func controlsSnapshot() -> ControlsSnapshot? {
    guard let directory = controlsDirectory() else { return nil }
    return ControlsSnapshot.read(from: ControlsPaths.snapshotURL(in: directory))
}

// MARK: - The group socket

/// Sends one request to the app, retrying once: the app may have just started,
/// and a control tap must not fail over that. Nil when no app answers.
func sendToApp(_ request: ControlsRequest, timeout: TimeInterval = 4) -> ControlsReply? {
    if let reply = sendToAppOnce(request, timeout: timeout) { return reply }
    controlsLog("\(request.command): retrying once")
    return sendToAppOnce(request, timeout: timeout)
}

/// One request and its one-line reply. nil when no app answers (not running,
/// or the socket is not there yet).
func sendToAppOnce(_ request: ControlsRequest, timeout: TimeInterval) -> ControlsReply? {
    guard let directory = controlsDirectory() else {
        controlsLog("\(request.command): no group container")
        return nil
    }
    let path = ControlsPaths.socketPath(in: directory)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        controlsLog("\(request.command): socket() failed errno=\(errno)")
        return nil
    }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        controlsLog("\(request.command): socket path too long")
        return nil
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes)
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
    }
    guard connected == 0 else {
        controlsLog("\(request.command): connect failed errno=\(errno)")
        return nil
    }
    guard var data = request.encoded() else { return nil }
    data.append(0x0A)
    let wrote = data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let n = write(fd, base.advanced(by: offset), raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
    guard wrote else {
        controlsLog("\(request.command): write failed errno=\(errno)")
        return nil
    }
    // The app answers one line. poll bounds the wait: a control tap must not
    // hang its UI when the app is busy.
    var buffer = Data()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 250)
        if ready < 0 { break }
        guard ready > 0 else { continue }
        var chunk = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
        if buffer.contains(0x0A) || buffer.count > 4096 { break }
    }
    if let newline = buffer.firstIndex(of: 0x0A) { buffer = buffer[..<newline] }
    guard let reply = ControlsReply.decode(Data(buffer)) else {
        controlsLog("\(request.command): no reply")
        return nil
    }
    controlsLog("\(request.command): ok=\(reply.ok) error=\(reply.error ?? "-")")
    return reply
}

// MARK: - Intents

/// The DND toggle. `SetValueIntent` is what ControlWidgetToggle requires; the
/// value is the state the person tapped, not the old one.
struct PhoneDndControlIntent: AppIntent, SetValueIntent {
    static var title: LocalizedStringResource = "Phone Do Not Disturb"
    static var openAppWhenRun = false

    @Parameter(title: "On")
    var value: Bool

    init() {}

    init(on: Bool) { value = on }

    func perform() async throws -> some IntentResult {
        controlsLog("perform dnd value=\(value)")
        _ = sendToApp(.dnd(value))
        return .result()
    }
}

struct RingControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Ring Phone"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        controlsLog("perform ring")
        _ = sendToApp(.ring)
        return .result()
    }
}

/// A button cycles normal → vibrate → silent → normal. It reads the snapshot
/// first so the request names the mode explicitly (`ringer silent`), which is
/// also what the e2e driver sends.
struct RingerControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Phone Ringer"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let current = controlsSnapshot()?.ringerMode ?? .normal
        let next = current.next
        controlsLog("perform ringer \(current.rawValue) -> \(next.rawValue)")
        _ = sendToApp(.ringer(next))
        return .result()
    }
}

/// "Open Contigua": the one action that is allowed to take focus, because
/// that is what the person asked for.
struct OpenContiguaIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Contigua"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        controlsLog("perform open")
        return .result()
    }
}

// MARK: - Values

struct DndControlState: Equatable {
    var on: Bool
    var available: Bool
}

struct DndValueProvider: ControlValueProvider {
    var previewValue: DndControlState { DndControlState(on: false, available: true) }

    func currentValue() async throws -> DndControlState {
        guard let snapshot = controlsSnapshot(), snapshot.connected, snapshot.dnd != nil else {
            return DndControlState(on: false, available: false)
        }
        return DndControlState(on: snapshot.dndOn, available: true)
    }
}

struct RingerControlState: Equatable {
    var mode: PhoneRingerMode?
    var available: Bool
    var enabled: Bool
}

struct RingerValueProvider: ControlValueProvider {
    var previewValue: RingerControlState {
        RingerControlState(mode: .normal, available: true, enabled: true)
    }

    func currentValue() async throws -> RingerControlState {
        guard let snapshot = controlsSnapshot(), snapshot.connected, snapshot.ringer != nil else {
            return RingerControlState(mode: nil, available: false, enabled: false)
        }
        return RingerControlState(mode: snapshot.ringerMode, available: true,
                                  enabled: !snapshot.dndOn)
    }
}

// MARK: - Controls

struct PhoneDndControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "app.contigua.mac.controls.dnd",
            provider: DndValueProvider()
        ) { state in
            ControlWidgetToggle(
                isOn: state.on,
                action: PhoneDndControlIntent(),
                label: {
                    if state.available {
                        Label("Phone Do Not Disturb", systemImage: "moon.fill")
                    } else {
                        Label("No phone", systemImage: "iphone.slash")
                            .foregroundStyle(.secondary)
                    }
                },
                valueLabel: { on in
                    Text(on ? "On" : "Off")
                }
            )
        }
        .displayName("Phone Do Not Disturb")
        .description("Turns your phone's Do Not Disturb on or off.")
    }
}

struct RingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.contigua.mac.controls.ring") {
            ControlWidgetButton(action: RingControlIntent()) {
                Label("Ring Phone", systemImage: "iphone.radiowaves.left.and.right")
            }
        }
        .displayName("Ring Phone")
        .description("Rings your phone for a few seconds so you can find it.")
    }
}

struct RingerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "app.contigua.mac.controls.ringer",
            provider: RingerValueProvider()
        ) { state in
            ControlWidgetButton(action: RingerControlIntent()) {
                if let mode = state.mode {
                    Label(title(for: mode), systemImage: symbol(for: mode))
                } else {
                    Label("Ringer", systemImage: "speaker.slash.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .displayName("Phone Ringer")
        .description("Cycles your phone's ringer: normal, vibrate, silent.")
    }

    private func title(for mode: PhoneRingerMode) -> LocalizedStringResource {
        switch mode {
        case .normal: return "Ringer: Normal"
        case .vibrate: return "Ringer: Vibrate"
        case .silent: return "Ringer: Silent"
        }
    }

    private func symbol(for mode: PhoneRingerMode) -> String {
        switch mode {
        case .normal: return "speaker.wave.2.fill"
        case .vibrate: return "iphone.radiowaves.left.and.right"
        case .silent: return "speaker.slash.fill"
        }
    }
}

struct OpenContiguaControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.contigua.mac.controls.open") {
            ControlWidgetButton(action: OpenContiguaIntent()) {
                Label("Open Contigua", systemImage: "rectangle.stack.fill")
            }
        }
        .displayName("Open Contigua")
        .description("Opens Contigua.")
    }
}

@main
struct ContiguaControls: WidgetBundle {
    var body: some Widget {
        PhoneDndControl()
        RingControl()
        RingerControl()
        OpenContiguaControl()
    }
}
