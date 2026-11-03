#if POCKETDECK_DIRECT
import Darwin
import Foundation

// The real helper (docs/design/direct-link.md §2). Only
// macos/scripts/direct/build.sh defines POCKETDECK_DIRECT; every other build
// compiles the stub below, so a public build carries no direct-link code.
setvbuf(stdout, nil, _IOLBF, 0)

do {
    let daemon = try DirectDaemon(config: DirectConfig.fromEnvironment())
    daemon.run()
} catch {
    FileHandle.standardError.write(Data("pocketdeck-directd: \(error)\n".utf8))
    exit(1)
}
#else
import Foundation

let name = ["POCKETDECK", "DIRECT"].joined(separator: "_")
FileHandle.standardError.write(Data("built without \(name)\n".utf8))
exit(2)
#endif
