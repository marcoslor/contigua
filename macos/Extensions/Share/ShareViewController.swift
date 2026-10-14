// The "Open on Phone" Share extension (docs/design/links.md). No UI of its own:
// it takes the shared link, hands it to the containing PocketDeck app (which
// picks the phone) and closes. Built by scripts/bundle.sh with swiftc together
// with Sources/PocketDeck/LinkShare.swift.

import AppKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        Task { @MainActor in
            var values: [Any] = []
            for provider in providers {
                for type in [UTType.url, UTType.plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                    if let value = await Self.load(provider, type: type) { values.append(value) }
                }
            }
            finish(link: ShareInput.link(from: values))
        }
    }

    private static func load(_ provider: NSItemProvider, type: UTType) async -> Any? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                nonisolated(unsafe) let item = item
                continuation.resume(returning: item)
            }
        }
    }

    private func finish(link: String?) {
        guard let link else {
            extensionContext?.cancelRequest(withError: CocoaError(.featureUnsupported))
            return
        }
        let app = ShareHandoff.containingApp(ofExtension: Bundle.main.bundleURL)
        let context = extensionContext
        nonisolated(unsafe) let unsafeContext = context
        ShareHandoff.send(link, toApp: app) { error in
            DispatchQueue.main.async {
                if let error { unsafeContext?.cancelRequest(withError: error) }
                else { unsafeContext?.completeRequest(returningItems: nil) }
            }
        }
    }
}
