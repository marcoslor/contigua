// Bonjour discovery of `_pocketdeck._tcp.` phones via NWBrowser. TXT records
// carry v/id/name/model (docs/PROTOCOL.md).

import Foundation
import Network

struct DiscoveredPhone: Equatable {
    var serviceName: String
    var deviceId: String
    var name: String
    var model: String
    var version: String?
    var endpoint: NWEndpoint
    /// The best interface the browser saw the phone on (Wi-Fi/Ethernet first).
    var interface: NWInterface?

    var ref: PhoneRef { PhoneRef(id: deviceId, name: name, model: model) }
}

/// One Bonjour browse result before it is merged with the same phone seen on
/// other interfaces.
struct DiscoveryCandidate {
    var serviceName: String
    var txt: [String: String]
    /// Lower is better: Wi-Fi/Ethernet before bridges, tunnels and loopback.
    var interfaceRank: Int
    var endpoint: NWEndpoint
    var interface: NWInterface? = nil
}

final class Discovery {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "dev.pocketdeck.discovery")
    private(set) var phones: [DiscoveredPhone] = []
    private(set) var browseState: String = "idle"

    /// Called on the main queue whenever the visible phone list changes.
    var onChange: (([DiscoveredPhone]) -> Void)?
    /// Called on the main queue when the system refuses to let us browse
    /// (Local Network permission denied) and again with false once it works.
    var onDenied: ((Bool) -> Void)?

    static let serviceType = "_pocketdeck._tcp"
    /// kDNSServiceErr_PolicyDenied: Local Network access was refused.
    private static let policyDenied: Int32 = -65570

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
            switch state {
            case .failed(let error), .waiting(let error):
                if case .dns(let code) = error, code == Self.policyDenied {
                    DispatchQueue.main.async { self.onDenied?(true) }
                }
            case .ready:
                DispatchQueue.main.async { self.onDenied?(false) }
            default:
                break
            }
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
        var candidates: [DiscoveryCandidate] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata { txt = record.dictionary }
            let best = result.interfaces.min { Self.rank($0) < Self.rank($1) }
            candidates.append(DiscoveryCandidate(serviceName: name, txt: txt,
                                                 interfaceRank: best.map(Self.rank) ?? 3,
                                                 endpoint: result.endpoint, interface: best))
        }
        let parsed = Self.phones(from: candidates)
        phones = parsed
        DispatchQueue.main.async { [weak self] in self?.onChange?(parsed) }
    }

    private static func rank(_ interface: NWInterface) -> Int {
        switch interface.type {
        case .wifi, .wiredEthernet: return 0
        case .cellular: return 1
        case .loopback: return 2
        default: return 3
        }
    }

    /// One phone per TXT `id`, however many interfaces advertise it. A result
    /// without a TXT `id` is skipped: it is the same service before its record
    /// arrived, and inventing an id from the service name made the phone unfindable
    /// once it was paired under its real one.
    static func phones(from candidates: [DiscoveryCandidate]) -> [DiscoveredPhone] {
        var best: [String: DiscoveryCandidate] = [:]
        for candidate in candidates {
            guard let id = candidate.txt["id"], !id.isEmpty else { continue }
            if let v = candidate.txt["v"], v != "1" { continue }
            if let current = best[id], current.interfaceRank <= candidate.interfaceRank { continue }
            best[id] = candidate
        }
        let parsed = best.map { id, candidate in
            DiscoveredPhone(serviceName: candidate.serviceName,
                            deviceId: id,
                            name: candidate.txt["name"] ?? candidate.serviceName,
                            model: candidate.txt["model"] ?? "",
                            version: candidate.txt["v"],
                            endpoint: candidate.endpoint,
                            interface: candidate.interface)
        }
        return parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension NWBrowser.Result.Metadata {
    var txtDictionary: [String: String] {
        if case let .bonjour(record) = self { return record.dictionary }
        return [:]
    }
}
