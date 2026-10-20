// The MCP stdio shim (docs/design/mcp.md): relays bytes between an MCP client's
// stdin/stdout and PocketDeck's private UNIX socket. It never interprets the
// JSON-RPC, so the app's MCPCore is the only implementation of the protocol.
//
// Built by macos/scripts/bundle.sh into Contents/Helpers/pocketdeck-mcp.

import Darwin
import Dispatch
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8], _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let written = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return write(fd, base.advanced(by: offset), count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        guard written > 0 else { return false }
        offset += written
    }
    return true
}

// --profile NAME: the same 1-32 of a-z, 0-9 and - rule Profile uses.
var profile = "default"
var index = 1
while index < CommandLine.arguments.count {
    switch CommandLine.arguments[index] {
    case "--profile":
        index += 1
        guard index < CommandLine.arguments.count else { fail("pocketdeck-mcp: --profile needs a name") }
        profile = CommandLine.arguments[index]
    default:
        fail("pocketdeck-mcp: unknown argument \(CommandLine.arguments[index])")
    }
    index += 1
}
let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
guard (1...32).contains(profile.count), profile.allSatisfy({ allowed.contains($0) }) else {
    fail("pocketdeck-mcp: --profile takes 1-32 of a-z, 0-9 and -")
}

guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                          in: .userDomainMask).first else {
    fail("pocketdeck-mcp: no Application Support folder")
}
let folder = profile == "default" ? "PocketDeck" : "PocketDeck-\(profile)"
let path = base.appendingPathComponent(folder, isDirectory: true)
    .appendingPathComponent("mcp.sock").path

let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard socketFD >= 0 else { fail("pocketdeck-mcp: socket: \(String(cString: strerror(errno)))") }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let nameBytes = Array(path.utf8)
guard nameBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    fail("pocketdeck-mcp: socket path is too long")
}
withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.copyBytes(from: nameBytes)
}
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let length = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socketFD, $0, length)
    }
}
guard connected == 0 else {
    // Missing (setting off) and refused (stale file) look the same to a client:
    // there is no server to talk to.
    fail("Turn on Settings › Automation in PocketDeck")
}
signal(SIGPIPE, SIG_IGN)

let stdinFD = FileHandle.standardInput.fileDescriptor
let stdoutFD = FileHandle.standardOutput.fileDescriptor

// Socket → stdout. When the app closes its end (setting turned off, "Disconnect
// agent", app quit) the relay ends and the shim exits cleanly.
DispatchQueue.global().async {
    var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(socketFD, &bytes, bytes.count)
        if count <= 0 { break }
        if !writeAll(stdoutFD, bytes, count) { break }
    }
    exit(0)
}

// stdin → socket. A client that closes its pipe ends the session; the app sees
// EOF, closes its side and the reader above exits the process.
var bytes = [UInt8](repeating: 0, count: 65536)
while true {
    let count = read(stdinFD, &bytes, bytes.count)
    if count <= 0 {
        shutdown(socketFD, SHUT_WR)
        break
    }
    if !writeAll(socketFD, bytes, count) { exit(0) }
}
dispatchMain()
