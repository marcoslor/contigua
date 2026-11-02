import Foundation
import Network
import WiFiAware

let svcName = "_nanprobe._tcp"
print("publishable:", WAPublishableService.allServices.keys.sorted())
print("subscribable:", WASubscribableService.allServices.keys.sorted())
guard let pub = WAPublishableService.allServices[svcName] ?? WAPublishableService.allServices.values.first else {
    print("no declared service; exiting")
    exit(0)
}
print("using service:", pub)
do {
    let listener = try NetworkListener(for: .wifiAware(.connecting(to: pub, from: .userSpecifiedDevices), active: .seconds(30)), ) { TCP() }
    listener.onStateUpdate { _, state in
        print("state:", state)
        if case .failed(let e) = state { print("ERROR:", e); exit(1) }
    }
    try await listener.run { conn in
        print("incoming connection:", conn)
    }
} catch {
    print("threw:", error)
    if let wa = (error as? NWError)?.wifiAware { print("WAError:", wa) }
}
