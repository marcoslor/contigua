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
    @Environment(\.openWindow) private var openWindow

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
        // The frame the profile remembers (DECK-19): placed once per open from
        // the pure rules in DeckPlacement, saved on every move and resize.
        .background { DeckWindowFrame() }
        // Previews stage the Settings screenshot; nothing else opens
        // the Settings window from here.
        .onChange(of: controller.settingsRequest) { _, _ in openSettings() }
        .onChange(of: controller.deckMode) { _, _ in
            // The toolbar is rebuilt with the mode (the title names the phone),
            // and the search field is SwiftUI's: the Find key goes back on it.
            if let window = DeckWindow.window { DeckSearch.applyFindHelp(in: window) }
        }
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
            // The menu bar panel is AppKit's and outside this scene; keep the
            // action that brings the Deck back after the window was closed.
            DeckWindow.openAction = { openWindow(id: DeckWindow.id) }
            // ⌘F is not a menu item, so the search field's help has to name it
            // (DECK-9/CONV-MAC-06). SwiftUI builds the toolbar field with the
            // window and again on a mode change: put the help on it now and
            // once more after the first layout pass.
            if let window = DeckWindow.window { DeckSearch.applyFindHelp(in: window) }
            // A launch hook's sheet waits for the window: presented while the
            // window is still being created, SwiftUI sometimes drops it.
            try? await Task.sleep(for: .seconds(0.3))
            if let window = DeckWindow.window { DeckSearch.applyFindHelp(in: window) }
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
            case .waiting:
                ProgressView().controlSize(.small)
                Text("Waiting for your phone…").font(.callout)
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

/// The Deck's status pill opens the same phone controls the menu bar panel
/// shows (docs/DESIGN.md "Deck"): one component, one copy.
struct DeckPhonePopover: View {
    @Environment(ConnectionController.self) private var controller

    var body: some View {
        PhonePanelView(
            state: PhoneControlsState(controller: controller),
            actions: PhoneControlsActions(controller: controller) { DeckWindow.show() },
        )
    }
}

struct PhoneDeckView: View {
    @Environment(ConnectionController.self) private var controller
    @State private var query = ""
    @State private var navigator = GridNavigator()
    @State private var showPanel = false
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
            ToolbarItem(placement: .navigation) {
                Button { showPanel = true } label: { StatusChip() }
                    .buttonStyle(.plain)
                    .help("Phone controls")
                    .accessibilityLabel("Phone controls")
                    .accessibilityIdentifier("deck.statusPill")
                    .popover(isPresented: $showPanel, arrowEdge: .bottom) {
                        DeckPhonePopover()
                            .environment(controller)
                    }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { controller.openPhoneWindow() } label: { Label("Phone", systemImage: "iphone.gen3") }
                    .disabled(!controller.link.isOnline)
                    .help("Open Phone Mirror")
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
        .onChange(of: controller.deckPanelRequest) { showPanel = true }
        .onChange(of: controller.sheet) { _, sheet in if sheet == nil { searchFocused = true } }
        .onChange(of: query) { navigator.selection = nil }
        .onAppear {
            searchFocused = true
            navigator.install(controller: controller, apps: { filtered }, clearQuery: { query = "" },
                              hasQuery: { !query.isEmpty },
                              setZoom: { delta in
                                  let store = Profile.active.defaults
                                  let next = delta.map { DeckZoom.stepped(from: DeckZoom.stored(in: store), by: $0) } ?? 1
                                  store.set(Double(next), forKey: DeckZoom.key)
                              })
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

/// The A–Z rail on the Deck's trailing edge (docs/design/mac-redesign.md
/// §3.3): one letter per app section, `#` for digits and symbols, and the
/// letter at the top of the grid in the accent colour. Pure, so the tests pin
/// the first index per letter and the letter a scroll offset lands on.
enum DeckRail {
    static let minimumApps = 30
    static let letters: [String] = (65...90).map { String(UnicodeScalar($0)!) } + ["#"]
    /// R1's one letter's hit target: 20 pt, the AGENTS minimum.
    static let pitch: CGFloat = 20
    /// The rail's full height at R1's pitch; shorter windows condense it
    /// (every other or every third letter) rather than shrink the targets.
    static let minimumHeight = CGFloat(letters.count) * pitch
    /// The condensed heights: 14 slots (every other letter) and 9 (every
    /// third). Both keep 20 pt targets.
    static let compactTwoHeight = CGFloat((letters.count + 1) / 2) * pitch
    static let compactThreeHeight = CGFloat((letters.count + 2) / 3) * pitch

    /// One rail slot: the first letter's index and how many letters it covers.
    struct Slot: Equatable {
        let first: Int
        let count: Int
    }

    struct Entry: Equatable {
        let letter: String
        /// The first app under this letter; nil draws the letter dimmed.
        let index: Int?
    }

    /// The letter a label files under: its first letter A–Z (accents fold),
    /// or `#` for a digit or symbol.
    static func letter(for label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let folded = String(first)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
        return folded.count == 1 && folded >= "A" && folded <= "Z" ? folded : "#"
    }

    /// One entry per drawn letter, in rail order, with its first app's index.
    static func entries(for apps: [AppInfo]) -> [Entry] {
        var first: [String: Int] = [:]
        for (index, app) in apps.enumerated() {
            let letter = letter(for: app.displayLabel)
            if first[letter] == nil { first[letter] = index }
        }
        return letters.map { Entry(letter: $0, index: first[$0]) }
    }

    /// The app a click on `letter` scrolls to: its own first app, or the next
    /// letter that has apps (dimmed letters skip forward).
    static func target(for letter: String, in entries: [Entry]) -> Int? {
        guard let start = entries.firstIndex(where: { $0.letter == letter }) else { return nil }
        return entries[start...].first { $0.index != nil }?.index
    }

    /// The first app in the row at the viewport's top. The row above may still
    /// reach into the viewport across the gutter: that makes it the current one.
    static func topIndex(offset: CGFloat?, apps: [AppInfo], metrics: DeckGridSize, width: CGFloat) -> Int? {
        guard !apps.isEmpty else { return nil }
        let columns = metrics.columns(forWidth: width)
        let pitch = metrics.cellHeight + metrics.rowSpacing
        let top = max(offset ?? 0, 0)
        let row = max(0, Int(floor((top - metrics.verticalInset - metrics.cellHeight) / pitch)) + 1)
        return min(row * columns, apps.count - 1)
    }

    /// The letter the scroll position is in.
    static func currentLetter(offset: CGFloat?, apps: [AppInfo], metrics: DeckGridSize,
                              width: CGFloat) -> String? {
        guard let index = topIndex(offset: offset, apps: apps, metrics: metrics, width: width) else {
            return nil
        }
        return rowLetter(rowStart: index, apps: apps, columns: metrics.columns(forWidth: width))
    }

    /// The rail is only useful on a full grid, and it gives way to search. A
    /// window too short for `minimumHeight` hides it through `ViewThatFits`,
    /// so a letter's 20 pt target is never shrunk or clipped.
    static func shows(count: Int, query: String) -> Bool {
        query.isEmpty && count >= minimumApps
    }

    /// The first app in the row that holds `index`.
    static func rowStart(containing index: Int, columns: Int) -> Int {
        guard columns > 0 else { return 0 }
        return max(index, 0) / columns * columns
    }

    /// The letter the rail accents for the row that starts at `rowStart`: the
    /// last section start inside that row, else the row's first tile. A row
    /// that flows from Slack into Telegram accents Telegram, so a jump to T
    /// reads T even though S fills most of the row (round 2).
    static func rowLetter(rowStart: Int, apps: [AppInfo], columns: Int) -> String? {
        guard apps.indices.contains(rowStart) else { return nil }
        let width = max(columns, 1)
        let end = min(rowStart + width, apps.count)
        var last: String?
        for index in rowStart..<end {
            let current = letter(for: apps[index].displayLabel)
            if index == rowStart || current != letter(for: apps[index - 1].displayLabel) {
                last = current
            }
        }
        return last
    }

    /// The letter the rail accents: the top visible row. While a click or drag
    /// jump is settling, the target's row will be the top one, so the accent
    /// moves at once instead of staying on the outgoing row (the prototype's
    /// lag).
    static func accentLetter(target: Int?, top: Int?, apps: [AppInfo], columns: Int) -> String? {
        guard !apps.isEmpty else { return nil }
        let index = target.map { rowStart(containing: $0, columns: columns) } ?? top
        guard let index else { return nil }
        return rowLetter(rowStart: index, apps: apps, columns: columns)
    }

    /// The letter at `y` in a column `height` tall; the letters share it evenly.
    static func letter(atY y: CGFloat, height: CGFloat, entries: [Entry]) -> String? {
        guard height > 0, !entries.isEmpty else { return nil }
        let fraction = min(max(y / height, 0), 0.999_999)
        return entries[Int(fraction * CGFloat(entries.count))].letter
    }

    /// The rail's slots at `height`: all 27 at 540 pt, every other letter at
    /// 280 pt, every third at 180 pt, and nothing below 8 slots. A slot's
    /// letters split its 20 pt row evenly, so a click at any y still lands on
    /// a real letter.
    static func slots(forHeight height: CGFloat) -> [Slot]? {
        guard height > 0 else { return nil }
        let capacity = Int((height / pitch).rounded(.down))
        guard capacity >= 8 else { return nil }
        let stride = max(1, (letters.count + capacity - 1) / capacity)
        guard (letters.count + stride - 1) / stride >= 8 else { return nil }
        var slots: [Slot] = []
        var first = 0
        while first < letters.count {
            let count = min(stride, letters.count - first)
            slots.append(Slot(first: first, count: count))
            first += count
        }
        return slots
    }

    /// The real letter under `y` in the condensed column.
    static func letter(atY y: CGFloat, slots: [Slot]) -> String? {
        guard !slots.isEmpty else { return nil }
        let top = CGFloat(slots.count) * pitch
        let clamped = min(max(y, 0), top - 0.0001)
        let slotIndex = min(Int(clamped / pitch), slots.count - 1)
        let slot = slots[slotIndex]
        let within = clamped - CGFloat(slotIndex) * pitch
        let band = min(slot.count - 1, max(0, Int(within / pitch * CGFloat(slot.count))))
        return letters[slot.first + band]
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
    /// ⌘+/⌘−/⌘0 on the Deck: a step's delta, or nil for 100 %.
    @ObservationIgnored private var setZoom: (CGFloat?) -> Void = { _ in }

    func install(controller: ConnectionController, apps: @escaping () -> [AppInfo],
                 clearQuery: @escaping () -> Void, hasQuery: @escaping () -> Bool,
                 setZoom: @escaping (CGFloat?) -> Void = { _ in }) {
        self.controller = controller
        self.apps = apps
        self.clearQuery = clearQuery
        self.hasQuery = hasQuery
        self.setZoom = setZoom
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
              NSApp.keyWindow === DeckWindow.window else { return false }
        // ⌘+ / ⌘− / ⌘0 scale the Deck grid, not a stream window's density
        // (that menu item is disabled while the Deck is key).
        if flags.contains(.command), flags.intersection([.control, .option]).isEmpty {
            switch keyCode {
            case 24, 69: setZoom(DeckZoom.step); return true       // = / + and keypad +
            case 27, 78: setZoom(-DeckZoom.step); return true      // - and keypad -
            case 29, 82: setZoom(nil); return true                 // 0 and keypad 0
            default: break
            }
        }
        // ⌘F is the Deck's Find: focus the search field and select what is
        // already typed, like ⌘F in any Mac window. It is not a menu item — a
        // menu item would eat ⌘F in a stream window, where the key belongs to
        // the phone's app (InputMapper forwards it). This monitor is the Deck's
        // only, so a stream window never reaches it.
        if keyCode == 3, flags.intersection([.command, .control, .option, .shift]) == .command {
            guard let deck = DeckWindow.window else { return false }
            DeckSearch.focusAndSelect(in: deck) { controller.requestSearchFocus() }
            return true
        }
        guard flags.intersection([.command, .control, .option]).isEmpty else { return false }
        let list = apps()
        switch keyCode {
        case 36, 76: // Return
            guard let target = list.first(where: { $0.id == selection }) ?? list.first else { return false }
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
            let current = list.firstIndex { $0.id == selection }
            if let next = GridNavigation.move(current, count: list.count, columns: columns, direction) {
                selection = list[next].id
            }
            return true
        default:
            return false
        }
    }
}

/// One drawn cell: the app and the identity the grid keys it by. Two cells with
/// the same id draw as nothing (the reported empty slot), so the identity lives
/// in `AppInfo.id` and this type is what the grid and its e2e dump share.
struct DeckCell: Identifiable, Equatable {
    let app: AppInfo
    var id: String { app.id }
    var label: String { app.displayLabel }
}

/// The Deck's zoom: ⌘+ / ⌘− / ⌘0 on the Deck scale the whole grid (cell, icon,
/// gaps and the 880 pt block) together. One stored fraction, clamped to the
/// same four steps as the app windows' density.
enum DeckZoom {
    static let key = "deckZoom"
    static let options: [CGFloat] = [0.75, 1.0, 1.25, 1.5]
    static let step: CGFloat = 0.25
    static let range: ClosedRange<CGFloat> = 0.75...1.5

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// One ⌘+/⌘− step, rounded to three places so 0.75 + 0.25 is exactly 1.
    static func stepped(from value: CGFloat, by delta: CGFloat) -> CGFloat {
        clamped((value + delta).rounded(toPlaces: 3))
    }

    /// 100% when the profile has no usable value.
    static func stored(in defaults: UserDefaults) -> CGFloat {
        let value = defaults.double(forKey: key)
        return value > 0 ? clamped(value) : 1
    }
}

/// The grid's numbers at one zoom step. Pure, so the layout, the cell views and
/// the unit tests all read the same arithmetic: 64 pt icons in 96×108 pt cells
/// on a fixed 16 pt pitch, a 24 pt vertical inset, an 8 pt icon-label gap, a
/// 16 pt hover corner and an 880 pt content block that stops growing.
struct DeckGridSize: Equatable {
    let zoom: CGFloat

    init(zoom: CGFloat) {
        self.zoom = DeckZoom.clamped(zoom)
    }

    var cellWidth: CGFloat { 96 * zoom }
    var cellHeight: CGFloat { 108 * zoom }
    var iconSide: CGFloat { 64 * zoom }
    var columnGap: CGFloat { 16 * zoom }
    var rowSpacing: CGFloat { 16 * zoom }
    var verticalInset: CGFloat { 24 * zoom }
    var iconLabelGap: CGFloat { 8 * zoom }
    var cornerRadius: CGFloat { 16 * zoom }
    /// The grid never runs edge to edge: at 1000 pt this leaves 60 pt a side.
    var maxContentWidth: CGFloat { 880 * zoom }

    /// Columns are what fits the block, never fewer than one.
    func columns(forWidth width: CGFloat) -> Int {
        max(Int((min(max(width, 0), maxContentWidth) + columnGap) / (cellWidth + columnGap)), 1)
    }

    /// The pitch never grows: a row keeps 16 pt between columns at any width.
    func gap(forWidth width: CGFloat) -> CGFloat { columnGap }

    /// The drawn width of one full row.
    func span(forWidth width: CGFloat) -> CGFloat {
        let count = columns(forWidth: width)
        return CGFloat(count) * cellWidth + CGFloat(max(count - 1, 0)) * columnGap
    }

    /// The block is centred, so the margins match on both sides.
    func originX(forWidth width: CGFloat) -> CGFloat {
        (width - span(forWidth: width)) / 2
    }

    /// Where cell `index` is drawn in a grid `width` wide.
    func frame(of index: Int, in width: CGFloat, origin: CGPoint = .zero) -> CGRect {
        let count = columns(forWidth: width)
        let column = index % count
        let row = index / count
        return CGRect(x: origin.x + originX(forWidth: width) + CGFloat(column) * (cellWidth + columnGap),
                      y: origin.y + verticalInset + CGFloat(row) * (cellHeight + rowSpacing),
                      width: cellWidth, height: cellHeight)
    }

    func height(for count: Int, width: CGFloat) -> CGFloat {
        let columns = columns(forWidth: width)
        let rows = (count + columns - 1) / columns
        return 2 * verticalInset + CGFloat(rows) * cellHeight
            + CGFloat(max(rows - 1, 0)) * rowSpacing
    }
}

/// The grid at 100 %: the D design's numbers, unchanged for callers that do
/// not carry the run's zoom.
enum GridMetrics {
    static let cellWidth: CGFloat = 96
    static let cellHeight: CGFloat = 108
    static let iconSide: CGFloat = 64
    static let columnGap: CGFloat = 16
    static let rowSpacing: CGFloat = 16
    static let verticalInset: CGFloat = 24
    static let iconLabelGap: CGFloat = 8
    static let cornerRadius: CGFloat = 16
    static let maxContentWidth: CGFloat = 880

    static func columns(forWidth width: CGFloat, zoom: CGFloat = 1) -> Int {
        DeckGridSize(zoom: zoom).columns(forWidth: width)
    }

    static func gap(forWidth width: CGFloat, zoom: CGFloat = 1) -> CGFloat {
        DeckGridSize(zoom: zoom).gap(forWidth: width)
    }

    static func span(forWidth width: CGFloat, zoom: CGFloat = 1) -> CGFloat {
        DeckGridSize(zoom: zoom).span(forWidth: width)
    }

    static func originX(forWidth width: CGFloat, zoom: CGFloat = 1) -> CGFloat {
        DeckGridSize(zoom: zoom).originX(forWidth: width)
    }
}

struct AppGrid: View {
    @Environment(ConnectionController.self) private var controller
    let apps: [AppInfo]
    let query: String
    let navigator: GridNavigator
    @AppStorage(DeckZoom.key, store: Profile.active.defaults) private var zoom = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The letter at the top of the grid, and the last scroll position that
    /// produced it (the rail's accent and the e2e's landing proof).
    @State private var currentLetter: String?
    @State private var scrollBox = RailScrollBox()
    /// The rail's pending target index: reported once its row is on screen.
    @State private var railTarget: Int?

    private var metrics: DeckGridSize { DeckGridSize(zoom: CGFloat(zoom)) }

    var body: some View {
        #if PD_TEST_HOOKS
        // The e2e's pointer-move proof counts grid bodies (deckbodycount); a
        // count that moves is the regression, so the call sits here, not in a
        // child the pointer could invalidate.
        DeckGridProbe.noteBody()
        #endif
        return ScrollViewReader { proxy in

            ScrollView {
                Group {
                    if apps.isEmpty && !controller.appsLoaded && query.isEmpty {
                        grid { ForEach(0..<12, id: \.self) { _ in PlaceholderCell(metrics: metrics) } }
                            .redacted(reason: .placeholder)
                    } else if apps.isEmpty {
                        Text("No apps match “\(query)”")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        grid {
                            ForEach(cells) { cell in
                                AppCell(app: cell.app, icon: controller.icons[cell.app.pkg],
                                        rendered: controller.deckIcons[cell.app.pkg],
                                        iconIsMissing: iconIsMissing(cell.app),
                                        metrics: metrics,
                                        selected: navigator.selection == cell.id) { controller.openApp(cell.app) }
                                    .id(cell.id)
                                    .deckCellGeometry(cell.id)
                                    .contextMenu { DockMenuItems(app: cell.app) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .task(id: cells.map(\.id)) {
                DeckGridProbe.report(cells, icons: controller.icons,
                                     rendered: controller.deckIcons,
                                     missing: controller.missingIcons,
                                     online: controller.link.isOnline)
            }
            // The scroll view's own width: the grid is laid out in it and never
            // sizes itself, so it follows the window instead of holding an old
            // width (the clipped edges during a zoom).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { outer in
                DeckGridMetrics.noteViewport(outer)
                // The approach zone is measured from the rail's leading edge,
                // at a y in the rail's own space, so a hover point needs the
                // container's size. Written only on a change, and only the
                // rail reads it.
                RailPointerModel.shared.noteContainerSize(outer.size)
                // Arrow keys move by the drawn columns. The drawn layout comes
                // from the layout pass itself (DeckGridLayout); this is only
                // the keyboard's copy of the same number and no view reads it.
                let current = metrics
                navigator.columns = current.columns(forWidth: outer.width)
                DeckGridProbe.reportGeometry(current, viewport: outer.width)
            }
            // The rail's current letter follows the scroll position. Only a
            // scroll is read here; the grid's layout never sees this value.
            .onScrollGeometryChange(for: RailScroll.self) { geometry in
                RailScroll(offset: geometry.visibleRect.minY + geometry.contentInsets.top,
                           width: geometry.containerSize.width)
            } action: { _, scroll in
                follow(scroll)
            }
            .overlay(alignment: .trailing) {
                if DeckRail.shows(count: cells.count, query: query) {
                    // R1 sits inside the content inset, left of the scroller.
                    // The rail picks the most letters whose rest pitch keeps
                    // room for the magnified overshoot (RailLayout.fit), and
                    // condenses below 18 pt.
                    DeckIndexRail(entries: railEntries, counts: railCounts,
                                  current: currentLetter ?? firstRailLetter) { letter in
                        scroll(to: letter, proxy: proxy)
                    }
                    .padding(.trailing, DeckIndexRail.trailingPadding)
                    // A growing rail may draw past its rest rows (S1/S3); the
                    // clip is the content inset, so nothing lands under the
                    // toolbar or over the grid.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .clipped()
                }
            }
            // The pointer is tracked on the grid's container, so the approach
            // zone covers the grid plus the rail. Tracking only: the zone never
            // takes a click or a hover from the last icon column.
            .onContinuousHover { phase in trackRail(phase) }
            .onChange(of: navigator.selection) { _, pkg in
                if let pkg { withAnimation(.smooth(duration: 0.15)) { proxy.scrollTo(pkg) } }
            }
            // The e2e cannot point in a quiet run: its `deck-rail` verb asks
            // for the same scroll the rail's own click runs.
            .onChange(of: controller.deckRailRequest) { _, request in
                if let request { scroll(to: request.letter, proxy: proxy) }
            }
        }
    }

    /// What the grid draws: one cell per launch target, never two cells with
    /// the same id (a phone can repeat an entry; SwiftUI draws a repeated id as
    /// an empty slot). The order the phone sent is kept.
    private var cells: [DeckCell] { AppGrid.entries(apps) }

    /// The rail follows the drawn cells, so its indexes are the grid's.
    private var cellApps: [AppInfo] { cells.map(\.app) }
    private var railEntries: [DeckRail.Entry] { DeckRail.entries(for: cellApps) }
    private var firstRailLetter: String? { railEntries.first { $0.index != nil }?.letter }

    /// Apps per letter, for R1's hover tag.
    private var railCounts: [String: Int] {
        cellApps.reduce(into: [:]) { counts, app in
            counts[DeckRail.letter(for: app.displayLabel), default: 0] += 1
        }
    }

    /// Scroll to a rail letter: its own first app, or the next letter with apps
    /// when the letter itself is empty.
    private func scroll(to letter: String, proxy: ScrollViewProxy) {
        guard let index = DeckRail.target(for: letter, in: railEntries),
              cells.indices.contains(index) else { return }
        railTarget = index
        DeckGridProbe.reportRailPick(letter: letter, index: index)
        withAnimation(.smooth(duration: 0.15)) { proxy.scrollTo(cells[index].id, anchor: .top) }
        // A target already on screen scrolls nowhere, so no geometry change
        // follows: report the landing from the position we have.
        if let last = scrollBox.last { follow(last) }
    }

    /// The letter (and, for a rail click, the target) at a scroll position.
    /// While a jump settles the accent is the target's row, so it moves at
    /// once instead of staying on the outgoing row (the prototype's lag).
    private func follow(_ scroll: RailScroll) {
        scrollBox.last = scroll
        let apps = cellApps
        guard let top = DeckRail.topIndex(offset: scroll.offset, apps: apps,
                                          metrics: metrics, width: scroll.width) else {
            currentLetter = nil
            return
        }
        let columns = metrics.columns(forWidth: scroll.width)
        let letter = DeckRail.accentLetter(target: railTarget, top: top, apps: apps,
                                           columns: columns)
        if letter != currentLetter { currentLetter = letter }
        if let target = railTarget {
            if top <= target, target < top + columns {
                railTarget = nil
                DeckGridProbe.reportRailTop(
                    letter: DeckRail.letter(for: apps[top].displayLabel), index: top)
            } else if top > target {
                // The person scrolled past the pending jump; stop holding it.
                railTarget = nil
            }
        }
    }

    /// The container hover, reduced to where the pointer is relative to the
    /// rail: `dx` points left of its leading edge, 0 inside it. The zone comes
    /// from `--debug-proto railzone=A<n>`; absent, `dx` 0 is today's on/off.
    private func trackRail(_ phase: HoverPhase) {
        let model = RailPointerModel.shared
        guard DeckRail.shows(count: cells.count, query: query) else {
            model.leave(reduceMotion: reduceMotion)
            return
        }
        switch phase {
        case .active(let point):
            // Before the first layout there is no container size to measure
            // against; the next hover point corrects it.
            guard model.containerSize.width > 0 else { return }
            // The rail is centred vertically in the container (the trailing
            // overlay), so the hover's y is shifted by that gap to reach the
            // rail's own coordinate space.
            let leading = model.containerSize.width - DeckIndexRail.trailingSpace
            let railHeight = CGFloat(model.slots.count) * DeckRail.pitch
            let top = max(0, (model.containerSize.height - railHeight) / 2)
            model.track(dx: max(0, leading - point.x), y: point.y - top,
                        zone: railZone, reduceMotion: reduceMotion)
        case .ended:
            model.leave(reduceMotion: reduceMotion)
        }
    }

    private var railZone: CGFloat { RailApproach.zone }

    /// Nothing more is coming for this icon: the phone said it has none, or
    /// the link is down.
    private func iconIsMissing(_ app: AppInfo) -> Bool {
        controller.missingIcons.contains(app.pkg) || !controller.link.isOnline
    }

    /// The cells the grid draws, one per id. Internal for the tests: a
    /// duplicate id is the person's empty slot.
    static func entries(_ apps: [AppInfo]) -> [DeckCell] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.id).inserted }.map(DeckCell.init)
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        DeckGridLayout(metrics: metrics) { content() }
            .frame(maxWidth: .infinity)
    }
}

/// The scroll position the rail reads: the content's visible top (the scroll
/// view has a toolbar inset above the grid) and the viewport width the letter
/// mapping needs. A value type so `onScrollGeometryChange` only calls back when
/// one of them changes.
private struct RailScroll: Equatable {
    var offset: CGFloat
    var width: CGFloat
}

/// The last scroll position for the rail's already-visible case. A reference
/// box, not @State: a resize changes the geometry every frame and must not
/// invalidate the grid's body (the e2e drag p95 is measured on exactly that).
private final class RailScrollBox {
    var last: RailScroll?
}

/// Dock-style magnification (R1): the letter under the pointer swells to
/// about 2× and its neighbours taper to 1× over three letters. Reduce Motion
/// keeps every letter at its rest size (CONV-MAC-22).
enum RailFisheye {
    static let maxScale: CGFloat = 2.2
    static let reach: CGFloat = 3

    /// `distance` is in letters from the pointer.
    static func scale(distance: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let t = max(0, 1 - abs(distance) / reach)
        return 1 + (maxScale - 1) * t * t * (3 - 2 * t)
    }

    /// The approach zone's ramp (proto/rail2): full size at the rail (`dx` 0)
    /// easing to rest at the zone's outer edge. `smoothstep` so the growth has
    /// no corner at either end; it is the same magnification, scaled.
    static func scale(distance: CGFloat, dx: CGFloat, zone: CGFloat,
                      reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let peak = scale(distance: distance, reduceMotion: false)
        guard zone > 0 else { return dx <= 0 ? peak : 1 }
        let t = min(max(1 - dx / zone, 0), 1)
        return 1 + (peak - 1) * t * t * (3 - 2 * t)
    }
}

/// Where the rail is on screen, for a visible VM run's real pointer
/// (`control deckrailpoint LETTER PATH`). The anchor is a zero-size view at the
/// rail's top-left; its window position plus the 20 pt pitch gives each letter's
/// centre in Quartz coordinates.
@MainActor
enum DeckRailPoint {
    static weak var anchor: NSView?

    /// The rail's top-left in Quartz screen coordinates (`deckrailanchor`), so
    /// a visible run can put the pointer on a letter it measured from the
    /// render instead of the letter-index arithmetic.
    static func anchorPoint(to path: String) -> Bool {
        guard let anchor, let window = anchor.window else { return false }
        let local = anchor.convert(anchor.bounds, to: nil)
        let screen = window.convertPoint(toScreen: NSPoint(x: local.minX, y: local.maxY))
        let top = window.screen?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        let text = "\(screen.x) \(top - screen.y)\n"
        return (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    static func point(letter: String, to path: String, dx: CGFloat = 0) -> Bool {
        guard let anchor, let window = anchor.window,
              let index = DeckRail.letters.firstIndex(of: letter) else { return false }
        let pitch = RailPointerModel.shared.railFit?.pitch ?? DeckRail.pitch
        let local = anchor.convert(anchor.bounds, to: nil)
        // On the rail (dx 0) the letter's own column; otherwise dx points left
        // of the rail's leading edge, for the real pointer's approach.
        let x = local.minX + (dx == 0 ? CGFloat(13) : -dx)
        let y = local.minY - (CGFloat(index) * pitch + pitch / 2)
        let screen = window.convertPoint(toScreen: NSPoint(x: x, y: y))
        let top = window.screen?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        let text = "\(screen.x) \(top - screen.y)\n"
        return (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
}

/// A zero-size AppKit anchor in the rail, so the debug route can read the
/// rail's real position (a SwiftUI view has no NSView of its own to ask).
private struct DeckRailAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DeckRailPoint.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DeckRailPoint.anchor = view
    }
}

/// A letter whose size follows the fisheye. A font is not itself animatable, so
/// the size is the animation's interpolated number: the ease back to rest runs
/// through this value frame by frame instead of swapping the glyph.
private struct RailLetterSize: ViewModifier, Animatable {
    var size: CGFloat
    let weight: Font.Weight

    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

/// R1: the A–Z rail on the Deck's trailing edge, inside the content inset and
/// clear of the scroller. The letter near the pointer magnifies, ramped by the
/// approach zone (proto/rail2) so it begins growing over the last icon column;
/// on the rail it names its app count; clicking or dragging a letter jumps the
/// grid; the letter at the top of the grid is the accent one, and a letter with
/// no apps is dimmed.
private struct DeckIndexRail: View {
    private static let width: CGFloat = 26
    private static let tagHeight: CGFloat = 22
    /// The rail's gap to the scroller; the approach distance is measured from
    /// `width + gap`, the rail's leading edge.
    static let trailingPadding: CGFloat = 18
    static let trailingSpace: CGFloat = width + trailingPadding

    let entries: [DeckRail.Entry]
    let counts: [String: Int]
    let current: String?
    let pick: (String) -> Void

    @State private var lastPicked: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The rail this window draws, from the container height: 27 letters at the
    /// largest pitch that keeps room for the magnified overshoot, 14 or 9 when
    /// it condenses. Static per window size, so the pitch never jitters.
    private var fit: (count: Int, pitch: CGFloat)? { RailPointerModel.shared.railFit }
    private var pitch: CGFloat { fit?.pitch ?? DeckRail.pitch }
    /// The rail's slots: 27 at full height, 14 or 9 when the window is short.
    private var slots: [DeckRail.Slot] {
        guard let fit else { return [] }
        return DeckRail.slots(forHeight: CGFloat(fit.count) * DeckRail.pitch) ?? []
    }
    private var height: CGFloat { CGFloat(slots.count) * pitch }
    private var currentIndex: Int? { current.flatMap(DeckRail.letters.firstIndex(of:)) }
    private var currentLetter: String? { currentIndex.map { DeckRail.letters[$0] } }
    /// The one pointer state; only the rail reads it, so a pointer over the
    /// grid never invalidates the grid's body.
    private var pointer: RailPointer { RailPointerModel.shared.state }
    private var zone: CGFloat { RailApproach.zone }

    /// The fisheye's scale per slot: the approach ramp (A2) times the taper.
    private var scales: [CGFloat] {
        slots.indices.map { index in
            guard let position = pointer.position else { return 1 }
            return RailFisheye.scale(distance: position.y / pitch - (CGFloat(index) + 0.5),
                                     dx: position.dx, zone: zone, reduceMotion: reduceMotion)
        }
    }

    /// The drawn slots: proportional to the scales with the rail's height
    /// fixed. The anchor is the pointer's y, so the letter under the pointer
    /// stays under it while the slots open.
    private var layout: [RailLayout.Slot] {
        RailLayout.slots(scales: scales, available: height, pitch: pitch,
                         anchor: pointer.position?.y)
    }

    /// The letter drawn under `y`: hit-testing follows the drawn layout.
    private func letter(atY y: CGFloat) -> String? {
        RailLayout.letter(atY: y, in: layout, slots: slots)
    }

    /// The slot and real letter level with the pointer (approach included, so
    /// a condensed slot names the letter it is growing towards).
    private var hovered: (slot: Int, letter: String)? {
        guard let position = pointer.position,
              let letter = letter(atY: position.y),
              let letterIndex = DeckRail.letters.firstIndex(of: letter),
              let slot = slotIndex(containing: letterIndex) else { return nil }
        return (slot, letter)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(index: index, slot: slot)
            }
        }
        .frame(width: Self.width, height: height, alignment: .topLeading)
        .background(alignment: .topLeading) {
            DeckRailAnchor().frame(width: 1, height: 1)
        }
        .contentShape(.rect)
        .overlay(alignment: .topTrailing) { helpTag }
        .gesture(drag)
        .onChange(of: slots, initial: true) { _, slots in
            // The forced e2e position (`deckrailapproach`) resolves a letter to
            // its band with the layout the rail is actually drawing.
            RailPointerModel.shared.slots = slots
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App index")
        .accessibilityValue(currentLetter ?? "")
        .accessibilityHint("Click or drag a letter to scroll to it")
    }

    private func slotIndex(containing letterIndex: Int) -> Int? {
        slots.firstIndex { letterIndex >= $0.first && letterIndex < $0.first + $0.count }
    }

    private func slotView(index: Int, slot: DeckRail.Slot) -> some View {
        let box = layout[index]
        let hoveredHere = hovered?.slot == index
        let range = slot.first..<(slot.first + slot.count)
        let containsCurrent = currentIndex.map(range.contains) ?? false
        let shown = hoveredHere ? (hovered?.letter ?? DeckRail.letters[slot.first])
            : containsCurrent ? (currentLetter ?? DeckRail.letters[slot.first])
            : DeckRail.letters[slot.first]
        let scale = scales[index]
        let highlighted = reduceMotion && pointer.showsHelpTag && hoveredHere
        let isCurrent = shown == currentLetter
        let hasApps = range.contains { entries[$0].index != nil }
        return HStack(spacing: 0) {
            Text(shown)
                .modifier(RailLetterSize(size: 9 * scale,
                                         weight: isCurrent || highlighted ? .semibold : .regular))
            if !hoveredHere && slot.count > 1 {
                // A bullet for each skipped letter in this slot, so the
                // condensed rail still reads as the whole alphabet.
                Text(String(repeating: "•", count: slot.count - 1))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor)
                                   : AnyShapeStyle(.secondary))
        .opacity(hasApps ? 1 : 0.35)
        .frame(width: Self.width, height: box.height)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(highlighted ? 0.12 : 0)))
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(slot))
        .accessibilityHint("Scrolls to \(DeckRail.letters[slot.first])")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pick(DeckRail.letters[slot.first]) }
        .offset(y: box.y)
    }

    /// The hovered real letter's tag, left of the rail and centred on its slot.
    /// Hovering and dragging only: gliding past in the approach zone shows no
    /// tag.
    @ViewBuilder
    private var helpTag: some View {
        if pointer.showsHelpTag, let hovered, layout.indices.contains(hovered.slot) {
            let count = counts[hovered.letter] ?? 0
            let box = layout[hovered.slot]
            Text(count == 0 ? "\(hovered.letter) · no apps"
                            : "\(hovered.letter) · \(count) \(count == 1 ? "app" : "apps")")
                .font(.caption)
                .padding(.horizontal, 8)
                .frame(height: Self.tagHeight)
                .background(.regularMaterial, in: .capsule)
                .fixedSize()
                .offset(x: -(Self.width + 6),
                        y: box.y + (box.height - Self.tagHeight) / 2)
                .allowsHitTesting(false)
        }
    }

    /// "M, 3 apps" for one letter; "A to B, 12 apps" for a condensed slot.
    private func accessibilityLabel(_ slot: DeckRail.Slot) -> String {
        let letters = Array(DeckRail.letters[slot.first..<(slot.first + slot.count)])
        let count = letters.reduce(0) { $0 + (counts[$1] ?? 0) }
        let name = letters.count == 1 ? letters[0] : "\(letters[0]) to \(letters[letters.count - 1])"
        return count == 0 ? "\(name), no apps" : "\(name), \(count) apps"
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let model = RailPointerModel.shared
                if model.state.isDragging {
                    model.drag(y: value.location.y, reduceMotion: reduceMotion)
                } else {
                    model.press(y: value.location.y, reduceMotion: reduceMotion)
                }
                guard let letter = letter(atY: value.location.y),
                      letter != lastPicked else { return }
                lastPicked = letter
                pick(letter)
            }
            .onEnded { value in
                lastPicked = nil
                RailPointerModel.shared.release(y: value.location.y, reduceMotion: reduceMotion)
            }
    }
}

/// The grid's placement. Columns and the centred block come from the width this
/// layout is given in the same pass that draws it: a stored width is still the
/// old one while a zoom or a live resize changes the window, and the fixed-width
/// columns past the edge are cut in half (the person's zoom-back frames).
/// Tiles keep 96 pt at 100 %; the pitch stays 16 pt.
struct DeckGridLayout: Layout {
    var metrics = DeckGridSize(zoom: 1)

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        MainActor.assumeIsolated { DeckGridMetrics.beginLayout() }
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: metrics.height(for: subviews.count, width: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        MainActor.assumeIsolated { DeckGridMetrics.relayouts += 1 }
        for (index, subview) in subviews.enumerated() {
            let frame = metrics.frame(of: index, in: bounds.width, origin: bounds.origin)
            subview.place(at: frame.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
        MainActor.assumeIsolated { DeckGridMetrics.endLayout() }
    }

    /// Where cell `index` is drawn in a grid `width` wide at 100 %. Pure, so the
    /// tests pin the design's 96 pt tiles and fixed 16 pt pitch at any width.
    static func frame(of index: Int, in width: CGFloat, origin: CGPoint = .zero) -> CGRect {
        DeckGridSize(zoom: 1).frame(of: index, in: width, origin: origin)
    }

    static func height(for count: Int, width: CGFloat) -> CGFloat {
        DeckGridSize(zoom: 1).height(for: count, width: width)
    }
}

/// Reports a drawn cell's frame to the zoom probe (`--debug-deck-zoom`). It is
/// attached only when a measurement was asked for, so a normal run has no
/// geometry observer on the cells at all.
private struct DeckCellGeometry: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        if DeckGridMetrics.recording {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                DeckGridMetrics.noteCell(id, frame)
            }
        } else {
            content
        }
    }
}

private extension View {
    func deckCellGeometry(_ id: String) -> some View { modifier(DeckCellGeometry(id: id)) }
}

struct AppCell: View {
    let app: AppInfo
    let icon: NSImage?
    /// The shared renderer's icon for the tile (docs/design/dock.md §Icons).
    let rendered: NSImage?
    let iconIsMissing: Bool
    /// The grid's numbers at the run's zoom step.
    let metrics: DeckGridSize
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false
    @AppStorage(GlassIconsSetting.key, store: Profile.active.defaults) private var glassIconsOn = true

    var body: some View {
        Button(action: open) {
            VStack(spacing: metrics.iconLabelGap) {
                AppIconView(app: app, image: icon, rendered: rendered, isMissing: iconIsMissing,
                            glassOn: glassIconsOn, hovering: hovering, side: metrics.iconSide)
                Text(app.displayLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(width: metrics.cellWidth, height: metrics.cellHeight)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                 : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: metrics.cornerRadius))
            .contentShape(.rect(cornerRadius: metrics.cornerRadius))
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
    var metrics = DeckGridSize(zoom: 1)

    var body: some View {
        VStack(spacing: metrics.iconLabelGap) {
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.quaternary)
                .frame(width: metrics.iconSide, height: metrics.iconSide)
            Text("Loading").font(.caption)
        }
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    }
}
