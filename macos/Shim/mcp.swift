// The MCP stdio shim (docs/design/mcp.md): relays bytes between an MCP client's
// stdin/stdout and Contigua's private UNIX socket. It never interprets the
// JSON-RPC, so the app's MCPCore is the only implementation of the protocol.
//
// Built by macos/scripts/bundle.sh into Contents/Helpers/contigua-mcp.

import Darwin
import Dispatch
import Foundation

private func usage() -> String {
    let lines = [
        "contigua-mcp — relays an MCP client's stdio to Contigua's automation socket.",
        "",
        "usage: contigua-mcp [--profile NAME]",
        "",
        "  --profile NAME  use NAME's socket (default: \"default\"); NAME is 1-32 of",
        "                  a-z, 0-9 and -.",
        "  --help, -h      print this usage and exit.",
        "",
        "The MCP client configuration line:",
        "  {\"command\": \"/Applications/Contigua.app/Contents/Helpers/contigua-mcp\"}",
        "For a named profile add \"args\": [\"--profile\", \"NAME\"].",
        "",
        "Socket paths:",
        "  ~/Library/Application Support/Contigua/mcp.sock          (default profile)",
        "  ~/Library/Application Support/Contigua-<profile>/mcp.sock (any other profile)",
        "",
        "Turn on Settings › Automation in Contigua",
    ]
    return lines.joined(separator: "\n")
}

private func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func writeStdout(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

private func fail(_ message: String) -> Never {
    writeStderr(message)
    exit(1)
}

/// The reason, then the usage, on stderr (MCP-12).
private func failUsage(_ reason: String) -> Never {
    writeStderr("contigua-mcp: \(reason)\n" + usage())
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

// --help / -h print the usage and exit 0 without connecting; an unknown
// argument or a bad --profile prints the reason and usage to stderr and
// exits 1 (MCP-12).
var profile = "default"
var index = 1
while index < CommandLine.arguments.count {
    let argument = CommandLine.arguments[index]
    switch argument {
    case "--help", "-h":
        writeStdout(usage())
        exit(0)
    case "--profile":
        index += 1
        guard index < CommandLine.arguments.count else { failUsage("--profile needs a name") }
        profile = CommandLine.arguments[index]
    default:
        failUsage("unknown argument \(argument)")
    }
    index += 1
}
let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
guard (1...32).contains(profile.count), profile.allSatisfy({ allowed.contains($0) }) else {
    failUsage("--profile takes 1-32 of a-z, 0-9 and -")
}

guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                          in: .userDomainMask).first else {
    fail("contigua-mcp: no Application Support folder")
}
let folder = profile == "default" ? "Contigua" : "Contigua-\(profile)"
let path = base.appendingPathComponent(folder, isDirectory: true)
    .appendingPathComponent("mcp.sock").path

let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard socketFD >= 0 else { fail("contigua-mcp: socket: \(String(cString: strerror(errno)))") }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let nameBytes = Array(path.utf8)
guard nameBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    fail("contigua-mcp: socket path is too long")
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
    fail("Turn on Settings › Automation in Contigua")
}
signal(SIGPIPE, SIG_IGN)

let stdinFD = FileHandle.standardInput.fileDescriptor
let stdoutFD = FileHandle.standardOutput.fileDescriptor

// Bytes relayed each way, guarded because the reader and writer run on
// different threads. The exit decision is the transport table in
// docs/design/mcp.md (MCP-11).
let relayLock = NSLock()
var halfClosed = false
var wroteToSocket = 0
var readFromSocket = 0

// Socket → stdout. When the socket closes, leave per the table: exit 1 only
// when the shim half-closed and relayed request bytes but got none back.
DispatchQueue.global().async {
    var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(socketFD, &bytes, bytes.count)
        if count <= 0 { break }
        relayLock.lock(); readFromSocket += count; relayLock.unlock()
        if !writeAll(stdoutFD, bytes, count) { break }
    }
    relayLock.lock()
    let closed = halfClosed
    let wrote = wroteToSocket
    let readBack = readFromSocket
    relayLock.unlock()
    if closed && wrote > 0 && readBack == 0 {
        fail("contigua-mcp: the app closed the connection with no reply")
    }
    exit(0)
}

// stdin → socket. On stdin EOF the shim half-closes its write side and keeps
// relaying until the app closes, so a pending reply is drained (MCP-10).
var bytes = [UInt8](repeating: 0, count: 65536)
while true {
    let count = read(stdinFD, &bytes, bytes.count)
    if count <= 0 {
        relayLock.lock(); halfClosed = true; relayLock.unlock()
        shutdown(socketFD, SHUT_WR)
        break
    }
    relayLock.lock(); wroteToSocket += count; relayLock.unlock()
    if !writeAll(socketFD, bytes, count) {
        // The socket is gone (setting off, Disconnect, quit) while stdin is
        // still open: the app closed first, so relay what arrived and exit 0.
        exit(0)
    }
}
dispatchMain()
