// The Deck: the one home window. Welcome, Nearby and the phone's app grid are
// states of it, chosen by what this Mac remembers (docs/design/mac-redesign.md §2–3).

import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension DeckSheet: Identifiable {
    var id: String {
        switch self {
        case .code: return "code"
        case .qr: return "qr"
        case .manual: return "manual"
        case .addPhone: return "addPhone"
        }
    }
}

struct DeckRoot: View {
    @Environment(ConnectionController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        ZStack {
            switch controller.deckMode {
            case .welcome: WelcomeView()
            case .nearby: NearbyView()
            case .phone: PhoneDeckView()
            }
        }
        .animation(.smooth(duration: 0.3), value: controller.deckMode)
        .frame(minWidth: 560, minHeight: 420)
        .task {
            // A launch hook's sheet waits for the window: presented while the
            // window is still being created, SwiftUI sometimes drops it.
            try? await Task.sleep(for: .seconds(0.3))
            controller.presentPendingSheet()
        }
        .sheet(item: $controller.sheet, onDismiss: { controller.sheetDismissed() }) { sheet in
            switch sheet {
            case .code: CodeSheet()
            case .qr: QRSheet()
            case .manual: ManualSheet()
            case .addPhone: NearbyView(isSheet: true).frame(width: 480, height: 460)
            }
        }
    }
}

// MARK: - Welcome

struct BrandGradient: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let stops: [Gradient.Stop] = scheme == .dark
            ? [.init(color: Color(hex: 0x1E2470), location: 0), .init(color: Color(hex: 0x3B1F73), location: 0.55),
               .init(color: Color(hex: 0x0D4E5C), location: 1)]
            : [.init(color: Color(hex: 0x6A7BFF), location: 0), .init(color: Color(hex: 0x9B6BFF), location: 0.55),
               .init(color: Color(hex: 0x3FD0E0), location: 1)]
        LinearGradient(stops: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

struct WelcomeView: View {
    @Environment(ConnectionController.self) private var controller

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 8) {
                Text("PocketDeck").font(.largeTitle.bold())
                Text("Your Android apps, on your Mac.").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                step("iphone.and.arrow.forward") { Text("Install PocketDeck on your phone") }
                step("bolt.badge.checkmark") {
                    HStack(spacing: 8) {
                        Text("Start Shizuku")
                        SwiftUI.Link("How?", destination: URL(string: "https://shizuku.rikka.app/guide/setup/")!)
                            .font(.callout)
                    }
                }
                step("wifi") { Text("Be on the same Wi-Fi") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                controller.markWelcomeSeen()
            } label: {
                Text("Find my phone").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .window) { BrandGradient() }
    }

    private func step<Content: View>(_ symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        Label {
            content().font(.body)
        } icon: {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(.tint)
        }
    }
}

// MARK: - Nearby

struct NearbyView: View {
    @Environment(ConnectionController.self) private var controller
    @State private var showSearching = false
    var isSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nearby").font(.headline)
                Spacer()
                if isSheet {
                    Button("Done") { controller.sheet = nil }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            content
            footer
        }
        .task {
            try? await Task.sleep(for: .seconds(0.4))
            showSearching = true
        }
    }

    @ViewBuilder
    private var content: some View {
        let phones = controller.nearby
        if phones.isEmpty {
            VStack(spacing: 8) {
                if controller.browseDenied {
                    Image(systemName: "network.slash").font(.title).foregroundStyle(.secondary)
                    Text("PocketDeck needs Local Network access.").font(.body).foregroundStyle(.secondary)
                    Text("Open System Settings → Privacy & Security → Local Network.")
                        .font(.callout).foregroundStyle(.tertiary)
                    Button("Open Settings") { Banner.openLocalNetworkSettings() }.buttonStyle(.glass)
                } else if showSearching {
                    ProgressView().controlSize(.small)
                    Text("Looking for phones on this network…").font(.body).foregroundStyle(.secondary)
                    Text(controller.searchedLong ? "Still nothing? Try Pair with QR."
                                                 : "Make sure PocketDeck is open on your phone.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .multilineTextAlignment(.center)
            .transition(.opacity)
        } else {
            ScrollView {
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach(phones) { phone in NearbyRow(phone: phone) }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button { controller.startQRPairing() } label: { Label("Pair with QR", systemImage: "qrcode") }
                Button { controller.sheet = .manual } label: { Label("Connect manually…", systemImage: "network") }
            }
            .buttonStyle(.glass)
        }
        .padding(16)
    }
}

struct NearbyRow: View {
    @Environment(ConnectionController.self) private var controller
    let phone: NearbyPhone

    private var pairable: Bool { !phone.remembered || phone.needsPairing }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3").font(.system(size: 22)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.ref.name).font(.body)
                if !phone.ref.model.isEmpty { Text(phone.ref.model).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            if pairable {
                if phone.needsPairing { Text("Pair again").font(.subheadline).foregroundStyle(.orange) }
                Button(phone.needsPairing ? "Pair again" : "Pair") { controller.pair(phone) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            } else {
                Text("Paired").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(minHeight: 52)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .contentShape(.rect(cornerRadius: 14))
        .onTapGesture { if pairable { controller.pair(phone) } }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Phone mode

struct BannerView: View {
    @Environment(ConnectionController.self) private var controller
    let banner: Banner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(banner.text).font(.callout)
            Spacer(minLength: 8)
            if let title = banner.actionTitle {
                if banner.action == .pairAgain {
                    Button(title, action: perform).buttonStyle(.glassProminent).controlSize(.small)
                } else {
                    Button(title, action: perform).buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func perform() {
        switch banner.action {
        case .tryNow: controller.tryNow()
        case .pairAgain: controller.pairAgain()
        case .openSettings: Banner.openLocalNetworkSettings()
        case nil: break
        }
    }
}

extension Banner {
    static func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct StatusChip: View {
    @Environment(ConnectionController.self) private var controller

    var body: some View {
        if let chip = controller.link.chip {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(color(chip.style))
                    .symbolEffect(.pulse, isActive: chip.style == .pulsingOrange)
                Text(chip.text)
                if controller.link.isOnline, let status = controller.status {
                    Image(systemName: status.locked ? "lock.fill" : "lock.open.fill").foregroundStyle(.secondary)
                    if let battery = status.battery {
                        Image(systemName: batterySymbol(battery, charging: status.charging)).foregroundStyle(.secondary)
                        Text("\(battery)%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.3), value: chip)
            .help(helpText)
        }
    }

    private var helpText: String {
        guard controller.link.isOnline, let status = controller.status else { return "" }
        var parts = [status.locked ? "Phone locked" : "Phone unlocked"]
        if let battery = status.battery { parts.append("\(battery)%" + (status.charging ? ", charging" : "")) }
        return parts.joined(separator: ", ")
    }

    private func color(_ style: ChipStyle) -> Color {
        switch style {
        case .green: return .green
        case .orange, .pulsingOrange: return .orange
        case .grey: return .secondary
        }
    }

    private func batterySymbol(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct PhoneDeckView: View {
    @Environment(ConnectionController.self) private var controller
    @State private var query = ""
    @State private var navigator = GridNavigator()
    @FocusState private var searchFocused: Bool

    private var filtered: [AppInfo] { GridNavigation.filter(controller.apps, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            if let banner = controller.banner {
                BannerView(banner: banner)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            AppGrid(apps: filtered, query: query, navigator: navigator)
                .opacity(controller.link.isOnline ? 1 : 0.5)
                .allowsHitTesting(controller.link.isOnline)
                .animation(.smooth(duration: 0.3), value: controller.link.isOnline)
        }
        .animation(.smooth(duration: 0.3), value: controller.banner)
        .navigationTitle(controller.activePhone?.name ?? "PocketDeck")
        .toolbar {
            ToolbarItem(placement: .status) { StatusChip() }
            ToolbarItem(placement: .primaryAction) {
                Button { controller.openPhoneWindow() } label: { Label("Phone", systemImage: "iphone.gen3") }
                    .disabled(!controller.link.isOnline)
                    .help("Open the phone screen")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search apps")
        .searchFocused($searchFocused)
        .onChange(of: controller.searchFocusRequest) { searchFocused = true }
        .onChange(of: controller.sheet) { _, sheet in if sheet == nil { searchFocused = true } }
        .onChange(of: query) { navigator.selection = nil }
        .onAppear {
            searchFocused = true
            navigator.install(controller: controller, apps: { filtered }, clearQuery: { query = "" },
                              hasQuery: { !query.isEmpty })
        }
        .onDisappear { navigator.uninstall() }
    }
}

// MARK: - App grid

enum GridDirection { case left, right, up, down }

enum GridNavigation {
    static func filter(_ apps: [AppInfo], query: String) -> [AppInfo] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    /// The index selected after an arrow key; the first arrow selects the first cell.
    static func move(_ index: Int?, count: Int, columns: Int, _ direction: GridDirection) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        let columns = max(columns, 1)
        switch direction {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, count - 1)
        case .up: return index - columns >= 0 ? index - columns : index
        case .down: return index + columns < count ? index + columns : index
        }
    }
}

/// Arrow keys, Return and Esc for the grid. The search field owns the keyboard
/// (it is focused whenever the Deck shows), so these are caught with a local
/// monitor rather than SwiftUI focus.
@MainActor
@Observable
final class GridNavigator {
    var selection: String?
    var columns = 6

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var controller: ConnectionController?
    @ObservationIgnored private var apps: () -> [AppInfo] = { [] }
    @ObservationIgnored private var clearQuery: () -> Void = {}
    @ObservationIgnored private var hasQuery: () -> Bool = { false }

    func install(controller: ConnectionController, apps: @escaping () -> [AppInfo],
                 clearQuery: @escaping () -> Void, hasQuery: @escaping () -> Bool) {
        self.controller = controller
        self.apps = apps
        self.clearQuery = clearQuery
        self.hasQuery = hasQuery
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated { self?.handle(keyCode: keyCode, flags: flags) ?? false }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the key was used here and must not reach the search field.
    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard let controller, controller.sheet == nil,
              NSApp.keyWindow === DeckWindow.window,
              flags.intersection([.command, .control, .option]).isEmpty else { return false }
        let list = apps()
        switch keyCode {
        case 36, 76: // Return
            guard let target = list.first(where: { $0.pkg == selection }) ?? list.first else { return false }
            controller.openApp(target)
            return true
        case 53: // Esc
            guard hasQuery() else { return false }
            clearQuery()
            return true
        case 123, 124, 125, 126:
            let vertical = keyCode == 125 || keyCode == 126
            // Left/right belong to the text caret while there is text.
            guard vertical || !hasQuery() else { return false }
            let direction: GridDirection = [123: .left, 124: .right, 125: .down, 126: .up][keyCode]!
            let current = list.firstIndex { $0.pkg == selection }
            if let next = GridNavigation.move(current, count: list.count, columns: columns, direction) {
                selection = list[next].pkg
            }
            return true
        default:
            return false
        }
    }
}

struct AppGrid: View {
    @Environment(ConnectionController.self) private var controller
    let apps: [AppInfo]
    let query: String
    let navigator: GridNavigator

    private let cell: CGFloat = 96

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if apps.isEmpty && !controller.appsLoaded && query.isEmpty {
                    grid { ForEach(0..<12, id: \.self) { _ in PlaceholderCell() } }
                        .redacted(reason: .placeholder)
                } else if apps.isEmpty {
                    Text("No apps match “\(query)”")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    grid {
                        ForEach(apps, id: \.pkg) { app in
                            AppCell(app: app, icon: controller.icons[app.pkg],
                                    selected: navigator.selection == app.pkg) { controller.openApp(app) }
                                .id(app.pkg)
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                navigator.columns = max(Int((width - 32 + 8) / (cell + 8)), 1)
            }
            .onChange(of: navigator.selection) { _, pkg in
                if let pkg { withAnimation(.smooth(duration: 0.15)) { proxy.scrollTo(pkg) } }
            }
        }
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: 8)], spacing: 8) {
            content()
        }
        .padding(16)
    }
}

struct AppCell: View {
    let app: AppInfo
    let icon: NSImage?
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app.dashed").font(.title).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 13, style: .continuous))
                Text(app.label)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(width: 96, height: 100)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                 : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: selected)
        .accessibilityLabel(app.label)
    }
}

struct PlaceholderCell: View {
    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.quaternary).frame(width: 56, height: 56)
            Text("Loading").font(.caption)
        }
        .frame(width: 96, height: 100)
    }
}
