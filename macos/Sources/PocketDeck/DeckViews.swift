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
    @Environment(\.openSettings) private var openSettings

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
        .frame(minWidth: 640, minHeight: 420)
        // Previews stage the Settings → Devices screenshot; nothing else opens
        // the Settings window from here.
        .onChange(of: controller.settingsRequest) { _, _ in openSettings() }
        // A link dropped on the Deck opens on the phone (a .webloc file carries one too);
        // an app file (.apk, .apks, .xapk) installs on it; other files transfer
        // (docs/design/dragdrop.md).
        .dropDestination(for: URL.self) { urls, _ in
            let apps = urls.filter { $0.isFileURL && ApkBundle.kind(of: $0) != nil }
            let links = urls.compactMap { url in
                url.isFileURL ? OpenLinkRequest.webloc(at: url) : LinkPolicy.validate(url.absoluteString)
            }
            let files = urls.filter { $0.isFileURL && ApkBundle.kind(of: $0) == nil }
            if let app = apps.first { controller.installApk(app) }
            for link in links { controller.openLink(OpenLinkRequest(url: link)) }
            if !files.isEmpty { controller.dropFiles(files) }
            return !links.isEmpty || !apps.isEmpty || !files.isEmpty
        }
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
                Text(controller.displayName(for: phone.ref)).font(.body)
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

/// An app install in progress or just finished (docs/design/apk.md).
struct ApkInstallView: View {
    let installer: ApkInstaller

    var body: some View {
        HStack(spacing: 10) {
            switch installer.phase {
            case .idle:
                EmptyView()
            case .preparing(let name):
                ProgressView().controlSize(.small)
                Text("Preparing \(name)…").font(.callout)
            case .sending(let name, let fraction):
                Image(systemName: "arrow.down.app").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sending \(name) to the phone…").font(.callout)
                    ProgressView(value: fraction).progressViewStyle(.linear)
                }
            case .installing(let name):
                ProgressView().controlSize(.small)
                Text("Installing \(name)…").font(.callout)
            case .finished(let text, let ok):
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(text).font(.callout)
            }
            Spacer(minLength: 8)
            if installer.isBusy {
                Button("Cancel") { installer.cancel() }.buttonStyle(.glass).controlSize(.small)
            } else {
                Button("Dismiss", systemImage: "xmark") { installer.dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

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

/// Which battery glyph a level gets: the nearest quarter, a bolt while charging.
enum BatterySymbol {
    static func name(level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    static func isLow(level: Int, charging: Bool) -> Bool { !charging && level < 13 }
}

/// The toolbar's status pill. Connected is the green dot alone (the title
/// already names the phone); every other state says what it is. Lock shows
/// only while the phone is locked, which is the state PocketDeck promises to
/// work in; the battery shows its level in the glyph and the number.
struct StatusChip: View {
    @Environment(ConnectionController.self) private var controller

    var body: some View {
        if let chip = controller.link.chip {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(color(chip.style))
                    .symbolEffect(.pulse, isActive: chip.style == .pulsingOrange)
                if chip.style != .green { Text(chip.text) }
                if controller.link.isOnline, let status = controller.status {
                    if status.locked {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                    if let battery = status.battery {
                        let low = BatterySymbol.isLow(level: battery, charging: status.charging)
                        HStack(spacing: 3) {
                            Image(systemName: BatterySymbol.name(level: battery, charging: status.charging))
                            Text("\(battery)%").monospacedDigit()
                        }
                        .foregroundStyle(low ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.3), value: chip)
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(chip))
        }
    }

    private var helpText: String {
        guard controller.link.isOnline, let status = controller.status else { return "" }
        let phone = controller.link.phone.map { controller.displayName(for: $0) } ?? "the phone"
        var parts = ["Connected to \(phone)", status.locked ? "phone locked" : "phone unlocked"]
        if let battery = status.battery { parts.append("battery \(battery)%" + (status.charging ? ", charging" : "")) }
        return parts.joined(separator: ", ")
    }

    private func accessibilityText(_ chip: Chip) -> String {
        chip.style == .green ? helpText : chip.text
    }

    private func color(_ style: ChipStyle) -> Color {
        switch style {
        case .green: return .green
        case .orange, .pulsingOrange: return .orange
        case .grey: return .secondary
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
            if controller.filesDomain.needsSwitch {
                FilesFinderPromptLine()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if controller.apkInstaller.phase != .idle {
                ApkInstallView(installer: controller.apkInstaller)
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
        .animation(.smooth(duration: 0.3), value: controller.apkInstaller.phase)
        .animation(.smooth(duration: 0.3), value: controller.filesDomain.needsSwitch)
        .navigationTitle(controller.activePhone.map { controller.displayName(for: $0) } ?? "PocketDeck")
        .searchable(text: $query, placement: .toolbar, prompt: "Search apps")
        .searchFocused($searchFocused)
        .toolbar {
            // The header packs into two groups at any width: the traffic
            // lights, the connection chip and the title on the left; the
            // actions on the right. .status would float the chip in the
            // middle of the toolbar on macOS (docs/DESIGN.md "Deck").
            ToolbarItem(placement: .navigation) { StatusChip() }
            ToolbarItem(placement: .primaryAction) {
                Button { controller.openPhoneWindow() } label: { Label("Phone", systemImage: "iphone.gen3") }
                    .disabled(!controller.link.isOnline)
                    .help("Open the phone screen")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
            }
            // macOS pins the .toolbar search field at the trailing end of a
            // window toolbar, so it renders after the gear whatever order
            // the toolbar content declares (docs/DESIGN.md "Deck": Phone,
            // gear, search field).
            DefaultToolbarItem(kind: .search, placement: .primaryAction)
        }
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

/// The grid's geometry. Tiles keep their size; the gaps between columns grow
/// to fill the row, so the first tile starts and the last one ends exactly one
/// inset from the window's edges (the toolbar's own leading edge) at any width.
enum GridMetrics {
    static let cellWidth: CGFloat = 96
    static let cellHeight: CGFloat = 100
    static let minGap: CGFloat = 8
    static let inset: CGFloat = 20

    static func columns(forWidth width: CGFloat) -> Int {
        max(Int((width - 2 * inset + minGap) / (cellWidth + minGap)), 1)
    }

    static func gap(forWidth width: CGFloat) -> CGFloat {
        let count = columns(forWidth: width)
        guard count > 1 else { return minGap }
        return max((width - 2 * inset - CGFloat(count) * cellWidth) / CGFloat(count - 1), minGap)
    }
}

struct AppGrid: View {
    @Environment(ConnectionController.self) private var controller
    let apps: [AppInfo]
    let query: String
    let navigator: GridNavigator
    @State private var width: CGFloat = 760

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
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
                                        layers: controller.iconLayers[app.pkg],
                                        iconIsMissing: iconIsMissing(app),
                                        selected: navigator.selection == app.pkg) { controller.openApp(app) }
                                    .id(app.pkg)
                                    .contextMenu { DockMenuItems(app: app) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            // The scroll view's own width (the grid must not size itself, or it would never
            // shrink with the window) minus the space a legacy scroller takes.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { outer in
                let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
                width = outer - scroller
                navigator.columns = GridMetrics.columns(forWidth: width)
            }
            .onChange(of: navigator.selection) { _, pkg in
                if let pkg { withAnimation(.smooth(duration: 0.15)) { proxy.scrollTo(pkg) } }
            }
        }
    }

    /// Nothing more is coming for this icon: the phone said it has none, or
    /// the link is down.
    private func iconIsMissing(_ app: AppInfo) -> Bool {
        controller.missingIcons.contains(app.pkg) || !controller.link.isOnline
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let count = GridMetrics.columns(forWidth: width)
        let gap = GridMetrics.gap(forWidth: width)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(GridMetrics.cellWidth), spacing: gap), count: count),
                         alignment: .leading, spacing: 8) {
            content()
        }
        .padding(.horizontal, GridMetrics.inset)
        .padding(.vertical, 16)
    }
}

struct AppCell: View {
    let app: AppInfo
    let icon: NSImage?
    let layers: AppIconLayers?
    let iconIsMissing: Bool
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false
    @AppStorage(GlassIconsSetting.key, store: Profile.active.defaults) private var glassIconsOn = true

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                AppIconView(app: app, image: icon, layers: layers, isMissing: iconIsMissing,
                            glassOn: glassIconsOn, hovering: hovering)
                Text(app.label)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(width: GridMetrics.cellWidth, height: GridMetrics.cellHeight)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                 : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: selected)
        .animation(.smooth(duration: 0.2), value: hovering)
        .accessibilityLabel(app.label)
    }
}

/// "Add to Dock" on an app (docs/design/dock.md).
struct DockMenuItems: View {
    @Environment(ConnectionController.self) private var controller
    let app: AppInfo

    var body: some View {
        if controller.isInDock(app) {
            Button("Remove from Dock App") { controller.removeFromDock(app) }
        } else {
            Button("Add to Dock") { controller.addToDock(app) }
                .disabled(!controller.canAddToDock)
        }
    }
}

struct PlaceholderCell: View {
    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.quaternary).frame(width: 56, height: 56)
            Text("Loading").font(.caption)
        }
        .frame(width: GridMetrics.cellWidth, height: GridMetrics.cellHeight)
    }
}
