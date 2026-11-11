// The three pairing sheets over the Deck: the 6-digit code to compare, the QR,
// and the manual address (docs/design/mac-redesign.md §3.4–3.5).

import AppKit
import SwiftUI

/// "123456" as "123 456": the grouping both screens use, so the eye can match them.
func groupedPairingCode(_ code: String) -> String {
    guard code.count == 6 else { return code }
    return "\(code.prefix(3)) \(code.suffix(3))"
}

/// Numeric comparison: the phone and this sheet show the same code and the
/// person taps Allow on the phone. Nothing is typed here.
struct CodeSheet: View {
    @Environment(ConnectionController.self) private var controller

    private var state: Pairing? {
        if case .pairing(_, let state) = controller.link { return state }
        return nil
    }

    private var displayName: String {
        // A manual connection only knows an address, which is no name to show.
        guard let phone = controller.link.phone, !phone.id.isEmpty else { return "your phone" }
        return controller.displayName(for: phone, fallback: "your phone")
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Pair with \(displayName)")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if controller.pairingSucceeded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: controller.pairingSucceeded)
                    .frame(height: 60)
            } else if case .comparing(let code) = state {
                codeView(code)
            }
            line
            actions
        }
        .padding(32)
        .frame(width: 400)
    }

    /// After 20 s of waiting the prompt may be invisible on the phone because
    /// its notifications are off: say so, once the wait is long enough.
    @ViewBuilder
    private var slowHint: some View {
        if let started = controller.pairingStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let hint = PairingCopy.slowHint(after: context.date.timeIntervalSince(started)) {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func codeView(_ code: String) -> some View {
        Text(groupedPairingCode(code))
            .font(.system(size: 52, weight: .semibold, design: .monospaced))
            .kerning(4)
            .foregroundStyle(.primary)
            .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
            .frame(height: 60)
    }

    @ViewBuilder
    private var line: some View {
        switch state {
        case .contacting:
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Contacting \(displayName)…").font(.callout).foregroundStyle(.secondary)
                }
                slowHint
            }
        case .comparing:
            VStack(spacing: 6) {
                Text("Tap Allow on your phone if it shows the same code.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                slowHint
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Pairing…").font(.callout).foregroundStyle(.secondary)
            }
        case .denied(let until):
            VStack(spacing: 4) {
                Text(PairingCopy.denied).font(.callout).foregroundStyle(.red)
                countdown(until)
            }
        case .coolingDown(let until):
            // The phone's own 30 s window: trying again at once cannot work.
            VStack(spacing: 4) {
                Text(PairingCopy.coolingDown).font(.callout).foregroundStyle(.orange)
                countdown(until)
            }
        case .refused(let reason):
            Text(ConnectionFailure.message(for: reason, phoneName: displayName) ?? "Pairing is turned off on the phone.")
                .font(.callout).foregroundStyle(.red)
        case .timedOut:
            Text("Nobody tapped Allow in time. Try again.").font(.callout).foregroundStyle(.secondary)
        case .unreachable:
            Text("Couldn't reach \(displayName). Try again.").font(.callout).foregroundStyle(.secondary)
        case nil:
            if controller.pairingSucceeded { Text("Paired.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    /// The machine's deadline, drawn as the one number (R2): no new sentence.
    @ViewBuilder
    private func countdown(_ until: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Pairing.remaining(until: until, at: context.date)
            Text(PairingCopy.countdown(seconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .denied(let until), .coolingDown(let until):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    Button("Cancel") { controller.sheet = nil }.buttonStyle(.glass)
                    Button("Try again") { controller.retryPairing() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!Pairing.canTryAgain(until: until, at: context.date))
                }
            }
        case .timedOut, .unreachable, .refused:
            HStack(spacing: 8) {
                Button("Cancel") { controller.sheet = nil }.buttonStyle(.glass)
                Button("Try again") { controller.retryPairing() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .verifying:
            EmptyView()
        default:
            if !controller.pairingSucceeded {
                Button("Cancel") { controller.sheet = nil }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

struct QRSheet: View {
    @Environment(ConnectionController.self) private var controller

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan with Contigua on your phone")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let qr = controller.qr {
                ZStack {
                    if qr.succeeded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: qr.succeeded)
                            .transition(.opacity)
                    } else {
                        tile(for: qr)
                    }
                }
                .frame(width: 252, height: 252)
                .animation(.smooth(duration: 0.3), value: qr.succeeded)
                status(for: qr)
            }
            Button(controller.qr?.succeeded == true ? "Done" : "Cancel") { controller.sheet = nil }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 360)
    }

    private func tile(for qr: QRPairingState) -> some View {
        ZStack {
            // White in both appearances: scanners need the contrast.
            RoundedRectangle(cornerRadius: 16).fill(.white)
            if let image = QRCode.image(from: qr.payload.uri) {
                Image(nsImage: image).interpolation(.none).resizable().padding(16)
            }
        }
        .frame(width: 252, height: 252)
        .blur(radius: qr.expired ? 8 : 0)
        .overlay {
            if qr.expired {
                Button("Show new code") { controller.startQRPairing() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private func status(for qr: QRPairingState) -> some View {
        if qr.succeeded {
            Text("Paired.").font(.callout).foregroundStyle(.secondary)
        } else if qr.expired {
            Text("This code expired.").font(.caption).foregroundStyle(.secondary)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(qr.payload.remaining(now: context.date).rounded(.up))
                Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Waiting for your phone…").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct ManualSheet: View {
    @Environment(ConnectionController.self) private var controller
    @State private var host = ""
    @State private var port = ""

    private var parsedPort: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var valid: Bool { !trimmedHost.isEmpty && parsedPort != nil }

    var body: some View {
        VStack(spacing: 24) {
            Text("Connect manually").font(.title3.weight(.semibold))
            Form {
                TextField("Address", text: $host, prompt: Text("192.168.1.20"))
                TextField("Port", text: $port, prompt: Text("47000")).monospacedDigit()
            }
            .formStyle(.columns)
            HStack(spacing: 8) {
                Button("Cancel") { controller.sheet = nil }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    if let parsedPort { controller.connectManually(host: trimmedHost, port: parsedPort) }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(32)
        .frame(width: 400)
    }
}
