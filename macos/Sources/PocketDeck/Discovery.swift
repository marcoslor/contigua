// Bonjour discovery of `_pocketdeck._tcp.` phones via NWBrowser. TXT records
// carry v/id/name/model (docs/PROTOCOL.md).

import Foundation
import Network

struct DiscoveredPhone {
    var serviceName: String
    var deviceId: String
    var name: String
    var model: String
    var version: String?
    var endpoint: NWEndpoint
}

final class Discovery {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "dev.pocketdeck.discovery")
    private(set) var phones: [DiscoveredPhone] = []
    private(set) var browseState: String = "idle"

    /// Called on the main queue whenever the visible phone list changes.
    var onChange: (([DiscoveredPhone]) -> Void)?

    static let serviceType = "_pocketdeck._tcp"

    func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let text = String(describing: state)
            self.browseState = text
            Log.app.info("mDNS browser \(text, privacy: .public)")
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        browseState = "idle"
        phones = []
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var parsed: [DiscoveredPhone] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata { txt = record.dictionary }
            if let v = txt["v"], v != "1" { continue }
            parsed.append(DiscoveredPhone(serviceName: name,
                                          deviceId: txt["id"] ?? name,
                                          name: txt["name"] ?? name,
                                          model: txt["model"] ?? "",
                                          version: txt["v"],
                                          endpoint: result.endpoint))
        }
        parsed.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        phones = parsed
        let snapshot = parsed
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }
}

extension NWBrowser.Result.Metadata {
    var txtDictionary: [String: String] {
        if case let .bonjour(record) = self { return record.dictionary }
        return [:]
    }
}
