// Launcher: discovered phones -> pair -> app grid with a search field.
//
//   * discovering: phone list (double-click or Connect)
//   * awaiting code: 6-digit sheet
//   * connected: app grid (double-click or Return opens the first match),
//     "Phone" button, lock/battery from `state`.

import AppKit

final class LauncherWindowController: NSWindowController {
    let launcherView: LauncherView

    private lazy var codeSheetWindow: NSWindow = {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Pair with phone"
        sheet.contentView = codeSheetView
        codeSheetView.onSubmit = { [weak self] code in self?.model.submitPairCode(code) }
        return sheet
    }()
    private lazy var qrSheetWindow: NSWindow = {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Pair with QR"
        sheet.contentView = qrSheetView
        qrSheetView.onCancel = { [weak self] in self?.model.cancelQRPairing() }
        return sheet
    }()
    private let codeSheetView = CodeSheetView()
    private let qrSheetView = QRSheetView()
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        launcherView = LauncherView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "PocketDeck"
        window.minSize = NSSize(width: 560, height: 420)
        super.init(window: window)
        window.contentView = launcherView
        window.center()
        model.onChange = { [weak self] in self?.launcherView.refresh() }
        launcherView.onDismissCodeSheet = { [weak self] in self?.dismissCodeSheetIfNeeded() }
        model.onPairCodeSheet = { [weak self] in
            guard let self, let window = self.window else { return }
            self.codeSheetView.setPhoneName(model.phone?.name ?? "your phone")
            self.launcherView.refresh()
            window.makeKeyAndOrderFront(nil)
            if window.attachedSheet == nil { window.beginSheet(self.codeSheetWindow) }
            self.codeSheetView.focus()
        }
        model.onQRSheetChange = { [weak self] in self?.updateQRSheet() }
        launcherView.onPairWithQR = { [weak self] in self?.model.startQRPairing() }
        launcherView.refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Called by the launcher when the session leaves the code-entry state.
    func dismissCodeSheetIfNeeded() {
        guard let window, let sheet = window.attachedSheet, sheet === codeSheetWindow else { return }
        window.endSheet(sheet)
    }

    /// Show/hide the QR sheet and refresh its status line.
    func updateQRSheet() {
        guard let window else { return }
        if let payload = model.qrPayload {
            qrSheetView.setPayload(payload)
            qrSheetView.setStatus(model.phones.isEmpty
                ? "Looking for phones on this network…"
                : "Waiting for the scan… (\(model.phones.count) phone\(model.phones.count == 1 ? "" : "s") found)")
            window.makeKeyAndOrderFront(nil)
            if window.attachedSheet !== qrSheetWindow {
                if let attached = window.attachedSheet { window.endSheet(attached) }
                window.beginSheet(qrSheetWindow)
            }
        } else if window.attachedSheet === qrSheetWindow {
            window.endSheet(qrSheetWindow)
        }
    }

    @objc func focusSearch() {
        // Bring the launcher forward: ⌘K is meant to jump to the search field
        // even when an app window is key.
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(launcherView.searchFieldForFocus)
        launcherView.selectSearchText()
    }

    @objc func openPhoneWindow() {
        launcherView.openPhoneWindow()
    }
}

// MARK: - Pairing sheets

/// Sheet content: the 6-digit pairing code.
final class CodeSheetView: NSView {
    var onSubmit: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Enter the 6-digit code shown on your phone")
    private let codeField = NSTextField(string: "")
    private let pairButton = NSButton(title: "Pair", target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 150))
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.alignment = .center
        addSubview(titleLabel)
        codeField.alignment = .center
        codeField.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        codeField.placeholderString = "123456"
        codeField.target = self
        codeField.action = #selector(submit)
        addSubview(codeField)
        pairButton.target = self
        pairButton.action = #selector(submit)
        pairButton.keyEquivalent = "\r"
        addSubview(pairButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focus() { window?.makeFirstResponder(codeField) }

    func setPhoneName(_ name: String) {
        titleLabel.stringValue = "Enter the 6-digit code shown on \(name)"
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 16, y: bounds.height - 44, width: bounds.width - 32, height: 20)
        codeField.frame = NSRect(x: bounds.midX - 110, y: bounds.midY - 14, width: 220, height: 40)
        pairButton.frame = NSRect(x: bounds.midX - 60, y: 16, width: 120, height: 32)
    }

    @objc private func submit() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        onSubmit?(code)
    }
}

/// Sheet content: the pairing QR (docs/UX.md, "Pairing model").
final class QRSheetView: NSView {
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Scan this with PocketDeck on your phone")
    private let subtitleLabel = NSTextField(wrappingLabelWithString:
        "Open PocketDeck → “Pair new Mac” → “Scan QR code”.")
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 520))
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .center
        addSubview(titleLabel)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        addSubview(subtitleLabel)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(imageView)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        addSubview(statusLabel)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        addSubview(cancelButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setPayload(_ payload: PairingQRPayload) {
        imageView.image = QRCode.image(from: payload.uri)
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        titleLabel.frame = NSRect(x: 16, y: bounds.height - 40, width: width - 32, height: 20)
        subtitleLabel.frame = NSRect(x: 24, y: bounds.height - 74, width: width - 48, height: 30)
        let side = min(width - 80, bounds.height - 200)
        imageView.frame = NSRect(x: (width - side) / 2, y: bounds.height - 100 - side,
                                 width: side, height: side)
        statusLabel.frame = NSRect(x: 16, y: 62, width: width - 32, height: 20)
        cancelButton.frame = NSRect(x: bounds.midX - 60, y: 16, width: 120, height: 32)
    }

    @objc private func cancel() { onCancel?() }
}

// MARK: - Launcher view

final class LauncherView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: AppModel

    private let devicesPane = NSView()
    private let appsPane = NSView()

    private let phoneTitle = NSTextField(labelWithString: "Phones")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let devicesScroll = NSScrollView()
    private let devicesTable = NSTableView()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let qrButton = NSButton(title: "Pair with QR", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

    private let searchField = NSSearchField()
    private let phoneButton = NSButton(title: "Phone", target: nil, action: nil)
    private let stateLabel = NSTextField(labelWithString: "")
    private let gridScroll = NSScrollView()
    private let grid = AppGridView()

    private var selectedPhone: Int?
    private var lastRefreshState: UIState?

    /// Asks the window controller to dismiss the pairing sheet.
    var onDismissCodeSheet: (() -> Void)?
    /// Devices pane: "Pair with QR".
    var onPairWithQR: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 780, height: 600))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        for pane in [devicesPane, appsPane] { addSubview(pane) }

        // Devices
        phoneTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        devicesPane.addSubview(phoneTitle)
        hintLabel.textColor = .secondaryLabelColor
        devicesPane.addSubview(hintLabel)
        devicesTable.headerView = nil
        devicesTable.rowHeight = 44
        devicesTable.allowsEmptySelection = true
        devicesTable.dataSource = self
        devicesTable.delegate = self
        devicesTable.target = self
        devicesTable.doubleAction = #selector(connectSelected)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("phone"))
        column.width = 500
        devicesTable.addTableColumn(column)
        devicesScroll.documentView = devicesTable
        devicesScroll.hasVerticalScroller = true
        devicesScroll.borderType = .bezelBorder
        devicesPane.addSubview(devicesScroll)
        connectButton.target = self
        connectButton.action = #selector(connectSelected)
        connectButton.keyEquivalent = "\r"
        devicesPane.addSubview(connectButton)
        retryButton.target = self
        retryButton.action = #selector(retry)
        devicesPane.addSubview(retryButton)
        qrButton.target = self
        qrButton.action = #selector(pairWithQR)
        devicesPane.addSubview(qrButton)

        // Apps
        searchField.placeholderString = "Search apps"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchReturn)
        appsPane.addSubview(searchField)
        phoneButton.target = self
        phoneButton.action = #selector(openPhone)
        appsPane.addSubview(phoneButton)
        stateLabel.alignment = .right
        stateLabel.textColor = .secondaryLabelColor
        appsPane.addSubview(stateLabel)
        grid.onOpen = { [weak self] app in self?.model.windows?.openApp(pkg: app.pkg, activity: app.activity) }
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false
        appsPane.addSubview(gridScroll)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let bounds = self.bounds
        for pane in [devicesPane, appsPane] { pane.frame = bounds }
        let pad: CGFloat = 20

        phoneTitle.frame = NSRect(x: pad, y: bounds.height - 44, width: bounds.width - pad * 2, height: 20)
        devicesScroll.frame = NSRect(x: pad, y: 66, width: bounds.width - pad * 2, height: bounds.height - 126)
        hintLabel.frame = NSRect(x: pad, y: 44, width: bounds.width - pad * 2 - 300, height: 40)
        connectButton.frame = NSRect(x: bounds.width - pad - 120, y: 22, width: 120, height: 32)
        retryButton.frame = NSRect(x: bounds.width - pad - 120, y: 22, width: 120, height: 32)
        qrButton.frame = NSRect(x: bounds.width - pad - 274, y: 22, width: 140, height: 32)

        searchField.frame = NSRect(x: pad, y: bounds.height - 48, width: 320, height: 28)
        phoneButton.frame = NSRect(x: bounds.width - pad - 100, y: bounds.height - 52, width: 100, height: 32)
        stateLabel.frame = NSRect(x: bounds.width - pad - 380, y: bounds.height - 44, width: 270, height: 20)
        gridScroll.frame = NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: bounds.height - 84)
        if abs(grid.frame.width - gridScroll.contentSize.width) > 0.5 {
            grid.setFrameSize(NSSize(width: gridScroll.contentSize.width, height: grid.frame.height))
        }
    }

    // MARK: Refresh

    func refresh() {
        let state = model.uiState
        devicesPane.isHidden = !(state == .discovering || state == .connecting
            || state == .awaitingCode || isFailure(state))
        appsPane.isHidden = state != .connected
        if state != .awaitingCode { onDismissCodeSheet?() }

        devicesTable.reloadData()
        let isFailed = isFailure(state)
        retryButton.isHidden = !isFailed
        devicesScroll.isHidden = isFailed || model.phones.isEmpty
        connectButton.isHidden = isFailed || state != .discovering
        connectButton.isEnabled = selectedPhone != nil
        phoneTitle.stringValue = "Phones"

        switch state {
        case .discovering:
            hintLabel.stringValue = model.phones.isEmpty
                ? "Looking for PocketDeck phones on your network…"
                : "Select a phone and press Connect."
        case .connecting:
            hintLabel.stringValue = "Connecting…"
        case .failed(let reason):
            hintLabel.stringValue = model.errorText.map { "Connection failed: \($0) (\(reason))" }
                ?? "Connection failed (\(reason))"
        case .awaitingCode:
            hintLabel.stringValue = "Waiting for the pairing code…"
        case .connected:
            break
        }

        if state == .connected {
            if lastRefreshState != .connected { window?.makeFirstResponder(searchField) }
            updateStatus()
            grid.icons = model.icons
            grid.apps = filteredApps()
        }
        if lastRefreshState != state { needsLayout = true }
        lastRefreshState = state
    }

    private func isFailure(_ state: UIState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func filteredApps() -> [AppInfo] {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.label.localizedCaseInsensitiveContains(query) || $0.pkg.localizedCaseInsensitiveContains(query)
        }
    }

    private func updateStatus() {
        var parts: [String] = []
        parts.append(model.locked ? "🔒 Locked" : "🔓 Unlocked")
        if let battery = model.battery {
            parts.append(model.charging == true ? "\(battery)% ⚡" : "\(battery)%")
        }
        stateLabel.stringValue = parts.joined(separator: " · ")
    }

    // MARK: Actions

    @objc private func connectSelected() {
        guard let index = selectedPhone, index < model.phones.count else { return }
        model.connect(phone: model.phones[index])
    }

    @objc private func retry() { model.retry() }

    @objc private func pairWithQR() { onPairWithQR?() }

    @objc private func searchReturn() {
        guard let first = filteredApps().first else { return }
        model.windows?.openApp(pkg: first.pkg, activity: first.activity)
    }

    @objc private func openPhone() {
        model.windows?.openPhoneWindow()
    }

    @objc func focusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Exposed so the window controller can focus the field from a menu item.
    var searchFieldForFocus: NSView { searchField }

    func selectSearchText() {
        searchField.currentEditor()?.selectAll(nil)
    }

    @objc func openPhoneWindow() { openPhone() }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        grid.apps = filteredApps()
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { model.phones.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let phone = model.phones[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: phone.name)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let subtitle = NSTextField(labelWithString: [phone.model, phone.deviceId].filter { !$0.isEmpty }.joined(separator: " · "))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 8, y: 22, width: 460, height: 16)
        subtitle.frame = NSRect(x: 8, y: 5, width: 460, height: 14)
        cell.addSubview(title)
        cell.addSubview(subtitle)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedPhone = devicesTable.selectedRow >= 0 ? devicesTable.selectedRow : nil
        connectButton.isEnabled = selectedPhone != nil
    }
}

// MARK: - App grid

final class AppGridView: NSView {
    var apps: [AppInfo] = [] { didSet { rebuild() } }
    var icons: [String: NSImage] = [:] { didSet { rebuild() } }
    var onOpen: ((AppInfo) -> Void)?

    private var cells: [AppIconCell] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Return on the grid opens the first match, matching the search field.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, let first = apps.first {
            onOpen?(first)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    private func rebuild() {        guard apps.map(\.pkg) != cells.map(\.app.pkg) else {
            for cell in cells { cell.image = icons[cell.app.pkg] }
            return
        }
        for cell in cells { cell.removeFromSuperview() }
        cells = apps.map { app in
            let cell = AppIconCell(app: app, image: icons[app.pkg])
            cell.onOpen = { [weak self] opened in self?.onOpen?(opened) }
            cell.onSelect = { [weak self] selected in
                for other in self?.cells ?? [] where other !== selected { other.isSelected = false }
                if let self { self.window?.makeFirstResponder(self) }
            }
            addSubview(cell)
            return cell
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let cellWidth: CGFloat = 104
        let cellHeight: CGFloat = 112
        let inset: CGFloat = 12
        // The document view must be at least as wide as the clip view; NSScrollView
        // does not size it for us.
        let available = enclosingScrollView?.contentSize.width ?? bounds.width
        let width = max(available, cellWidth + inset * 2)
        let columns = max(Int((width - inset * 2) / cellWidth), 1)
        for (index, cell) in cells.enumerated() {
            let column = index % columns
            let row = index / columns
            cell.frame = NSRect(x: inset + CGFloat(column) * cellWidth,
                                y: inset + CGFloat(row) * cellHeight,
                                width: cellWidth, height: cellHeight)
        }
        let rows = (cells.count + columns - 1) / columns
        let height = max(inset * 2 + CGFloat(rows) * cellHeight, 1)
        if abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
    }
}

final class AppIconCell: NSView {
    let app: AppInfo
    var image: NSImage? { didSet { imageView.image = image ?? Self.placeholder } }
    var onOpen: ((AppInfo) -> Void)?
    var onSelect: ((AppIconCell) -> Void)?

    var isSelected = false { didSet { needsDisplay = true } }

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")

    private static var placeholder: NSImage? {
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
    }

    init(app: AppInfo, image: NSImage?) {
        self.app = app
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = image ?? Self.placeholder
        imageView.contentTintColor = image == nil ? .tertiaryLabelColor : nil
        addSubview(imageView)
        titleLabel.stringValue = app.label
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.maximumNumberOfLines = 2
        addSubview(titleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        imageView.frame = NSRect(x: (bounds.width - 64) / 2, y: 8, width: 64, height: 64)
        titleLabel.frame = NSRect(x: 2, y: 76, width: bounds.width - 4, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        isSelected = true
        onSelect?(self)
        if event.clickCount == 2 { onOpen?(app) }
    }
}
