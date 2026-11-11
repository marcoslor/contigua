// share-driver.swift — test driver for the "Open on Phone" Share extension.
// Compiled by check-e2e.sh together with Sources/Contigua/LinkShare.swift.
//
//   share-driver handoff <App.app> <shared text or URL>
//       runs the extension's own extraction + hand-off code (ShareInput, ShareHandoff)
//       outside the sandbox: the app at <App.app> receives the link.
//   share-driver service <service title> <url>
//       asks AppKit for the share services of <url> and performs the one with that
//       title, i.e. the real extension in its sandbox (needs it enabled in Settings).
//   share-driver list <url>
//       prints the titles of the share services offered for <url>.

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("share-driver: \(message)\n".utf8))
    exit(1)
}

final class Delegate: NSObject, NSSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { print("shared"); exit(0) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        fail("share failed: \(error.localizedDescription)")
    }
}

@main
enum ShareDriver {
    static func main() {
        let args = CommandLine.arguments
        switch args.count > 1 ? args[1] : "" {
        case "handoff" where args.count == 4:
            guard let link = ShareInput.link(from: [args[3]]) else { fail("no shareable link in input") }
            ShareHandoff.send(link, toApp: URL(fileURLWithPath: args[2])) { error in
                if let error { fail("hand-off failed: \(error.localizedDescription)") }
                print("handed off \(link)")
                exit(0)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(20))
            fail("hand-off timed out")
        case "list" where args.count == 3, "service" where args.count == 4:
            guard let url = URL(string: args.last!) else { fail("bad url") }
            let services = NSSharingService.sharingServices(forItems: [url])
            if args[1] == "list" {
                for service in services { print(service.title) }
                exit(0)
            }
            guard let service = services.first(where: { $0.title == args[2] }) else {
                fail("no share service titled '\(args[2])' (have: \(services.map(\.title)))")
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = Delegate()
            service.delegate = delegate
            DispatchQueue.main.async { service.perform(withItems: [url]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { fail("share timed out") }
            app.run()
        default:
            fail("usage: share-driver handoff <App.app> <text> | service <title> <url> | list <url>")
        }
    }
}
