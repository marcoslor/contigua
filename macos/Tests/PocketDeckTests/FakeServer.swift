import Network
import XCTest
@testable import PocketDeck

/// A TCP listener on loopback that records what its connections see.
final class FakeServer {
    let listener: NWListener
    private let queue = DispatchQueue(label: "fakeserver")
    private(set) var accepted: [NWConnection] = []
    var onData: ((NWConnection, Data) -> Void)?
    var onClosed: ((NWConnection) -> Void)?
    private let ready = DispatchSemaphore(value: 0)

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.accepted.append(connection)
            connection.start(queue: self.queue)
            self.read(connection)
        }
        listener.stateUpdateHandler = { [ready] state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onData?(connection, data) }
            if complete || error != nil { self.onClosed?(connection); return }
            self.read(connection)
        }
    }

    func send(_ connection: NWConnection, _ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    func stop() {
        listener.cancel()
        for connection in accepted { connection.cancel() }
    }
}
