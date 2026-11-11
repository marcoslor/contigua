// The Deck as a start page (ISS-74, D1 two rows): sections above All Apps, one
// shared column grid for every section, and the pins this Mac keeps per phone.
//
// The person's correction is the point of this file: a section is a range of
// cells in the SAME block as All Apps, so a tile in Pinned column 3 sits
// exactly above the All Apps tile in column 3 at every width. Nothing here
// stores a width: the layout computes the block from the width of the pass that
// draws it, as the grid has since the 10-21 zoom regression (DECK-4).

import AppKit
import SwiftUI

/// [DECK-26] One section of the start page. Order is the reading order: the
/// windows open on this Mac, the pins, then every app.
struct DeckSection: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Equatable {
        case openWindows = "open"
        case pinned = "pinned"
        case allApps = "all"
    }

    let kind: Kind
    let title: String
    let apps: [AppInfo]
    /// All Apps carries a header only while a section above it is shown, so a
    /// page with no window and no pin is exactly the grid the Deck had before
    /// (no header, no gap).
    let showsHeader: Bool

    var id: String { kind.rawValue }
}

/// [DECK-26] One cell of the page, in reading order. The key carries its
/// section, so the same app in Pinned and in All Apps is two tiles with two
/// selections, never two tiles lit at once.
struct DeckPageCell: Identifiable, Equatable {
    let section: DeckSection.Kind
    let app: AppInfo

    var id: String { "\(section.rawValue)/\(app.id)" }
}

/// [DECK-26] The page's sections, pure: what is shown, in what order, and what
/// is not shown at all. All Apps is sorted by name (ISS-74); the other two keep
/// their own order — the windows front to back, the pins in pin order.
enum DeckPage {
    static let openTitle = "Open on this Mac"
    static let pinnedTitle = "Pinned"
    static let allTitle = "All Apps"
    /// The pins' limit (ISS-74): the ninth tile is refused, not queued.
    static let pinnedLimit = 8
    /// The ninth pin's menu item's help tag (ISS-74).
    static let pinFullHelp = "You can pin up to eight apps."

    /// The page at one query. While searching the sections collapse to the
    /// results alone (today's behaviour, DECK-8): one All Apps section, no
    /// headers, no empty sections.
    static func sections(apps: [AppInfo], query: String, openPkgs: [String],
                         pinnedPkgs: [String]) -> [DeckSection] {
        let visible = sorted(GridNavigation.filter(unique(apps), query: query))
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [DeckSection(kind: .allApps, title: allTitle, apps: visible, showsHeader: false)]
        }
        var byPkg: [String: AppInfo] = [:]
        for app in visible where byPkg[app.pkg] == nil { byPkg[app.pkg] = app }

        var open: [AppInfo] = []
        var seen = Set<String>()
        for pkg in openPkgs where seen.insert(pkg).inserted {
            if let app = byPkg[pkg] { open.append(app) }
        }
        var pinned: [AppInfo] = []
        seen.removeAll()
        for pkg in pinnedPkgs where seen.insert(pkg).inserted {
            guard pinned.count < pinnedLimit else { break }
            if let app = byPkg[pkg] { pinned.append(app) }
        }

        var sections: [DeckSection] = []
        if !open.isEmpty {
            sections.append(DeckSection(kind: .openWindows, title: openTitle,
                                        apps: open, showsHeader: true))
        }
        if !pinned.isEmpty {
            sections.append(DeckSection(kind: .pinned, title: pinnedTitle,
                                        apps: pinned, showsHeader: true))
        }
        sections.append(DeckSection(kind: .allApps, title: allTitle, apps: visible,
                                    showsHeader: !sections.isEmpty))
        return sections
    }

    /// All Apps sorted by name, the way macOS sorts names ("App 2" before
    /// "App 10"): the phone's own order is not the rail's. Equal names keep a
    /// stable order by their id.
    static func sorted(_ apps: [AppInfo]) -> [AppInfo] {
        apps.sorted { first, second in
            let order = first.displayLabel.localizedStandardCompare(second.displayLabel)
            if order != .orderedSame { return order == .orderedAscending }
            return first.id < second.id
        }
    }

    /// One cell per launch target, in the phone's order, deduplicated by id:
    /// a repeated entry drew neither tile (DECK-3, the person's empty slot).
    static func unique(_ apps: [AppInfo]) -> [AppInfo] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.id).inserted }
    }

    /// Every visible cell in reading order: sections top to bottom, columns
    /// left to right.
    static func cells(_ sections: [DeckSection]) -> [DeckPageCell] {
        sections.flatMap { section in
            section.apps.map { DeckPageCell(section: section.kind, app: $0) }
        }
    }

    /// The page's visual rows. A row never crosses a section's boundary —
    /// a section starts a new row — and never holds more cells than the grid
    /// has columns. The arrow keys move over these rows (DECK-11/29).
    static func rows(_ sections: [DeckSection], columns: Int) -> [[DeckPageCell]] {
        let width = max(columns, 1)
        var rows: [[DeckPageCell]] = []
        for section in sections {
            var row: [DeckPageCell] = []
            for app in section.apps {
                row.append(DeckPageCell(section: section.kind, app: app))
                if row.count == width { rows.append(row); row = [] }
            }
            if !row.isEmpty { rows.append(row) }
        }
        return rows
    }

    /// The cell an arrow key moves to, over the page's own rows. The first
    /// arrow selects the first cell; left and right move one cell at a time
    /// through reading order; up and down keep the column and stay put when
    /// the next row is too short (today's rule, DECK-11).
    static func move(selection: String?, cells: [DeckPageCell],
                     rows: [[DeckPageCell]], _ direction: GridDirection) -> String? {
        guard !cells.isEmpty else { return nil }
        guard let selection,
              let index = cells.firstIndex(where: { $0.id == selection }) else {
            return cells[0].id
        }
        switch direction {
        case .left:
            return cells[max(index - 1, 0)].id
        case .right:
            return cells[min(index + 1, cells.count - 1)].id
        case .up, .down:
            guard let rowIndex = rows.firstIndex(where: { row in row.contains { $0.id == selection } }),
                  let column = rows[rowIndex].firstIndex(where: { $0.id == selection }) else {
                return selection
            }
            let target = direction == .up ? rowIndex - 1 : rowIndex + 1
            guard rows.indices.contains(target), rows[target].indices.contains(column) else {
                return selection
            }
            return rows[target][column].id
        }
    }
}

/// [DECK-26] Every frame the start page draws, from one block: the headers and
/// the cells of every section share the column x positions of All Apps. Pure,
/// so a test pins the alignment at the brief's widths without a window.
struct DeckPageLayout: Equatable {
    /// The page's own rhythm. The header sits at the grid's leading edge; the
    /// first header has a 10 pt top inset, a section's cells start 6 pt under
    /// its header, sections are 10 pt apart, and the page ends with the grid's
    /// own 24 pt inset. With no section above All Apps the grid keeps its
    /// original 24 pt top inset, so the page is today's grid exactly.
    static let headerTop: CGFloat = 10
    static let headerHeight: CGFloat = 13
    static let headerGap: CGFloat = 6
    static let sectionGap: CGFloat = 10

    let width: CGFloat
    let metrics: DeckGridSize
    let sections: [DeckSection]
    let block: DeckWide.Block
    /// One header frame per section that draws one, keyed by its kind.
    let headers: [DeckSection.Kind: CGRect]
    /// One frame per cell, section by section, in reading order.
    let cells: [[CGRect]]
    let height: CGFloat
    /// The y where the All Apps cells begin (row 0's top).
    let allAppsTop: CGFloat
    /// The y the All Apps grid's own coordinate space would start at: the
    /// scroll's measured offset is reduced by this for the rail's row mapping,
    /// which counts from the grid's 24 pt inset (DECK-7).
    var gridOrigin: CGFloat { allAppsTop - metrics.verticalInset }

    init(width: CGFloat, metrics: DeckGridSize, sections: [DeckSection]) {
        self.width = width
        self.metrics = metrics
        self.sections = sections
        let block = DeckWide.block(width: width, metrics: metrics)
        self.block = block
        let columns = max(block.columns, 1)
        var y = sections.first?.showsHeader == true ? Self.headerTop : metrics.verticalInset
        var headers: [DeckSection.Kind: CGRect] = [:]
        var cells: [[CGRect]] = []
        var allAppsTop = y
        for (index, section) in sections.enumerated() {
            if section.showsHeader {
                headers[section.kind] = CGRect(x: block.originX, y: y,
                                               width: block.span, height: Self.headerHeight)
                y += Self.headerHeight + Self.headerGap
            }
            if section.kind == .allApps { allAppsTop = y }
            let frames = section.apps.enumerated().map { offset, _ in
                let column = offset % columns
                let row = offset / columns
                return CGRect(
                    x: block.originX + CGFloat(column) * (metrics.cellWidth + metrics.columnGap),
                    y: y + CGFloat(row) * (metrics.cellHeight + metrics.rowSpacing),
                    width: metrics.cellWidth, height: metrics.cellHeight)
            }
            cells.append(frames)
            let rowCount = (section.apps.count + columns - 1) / columns
            if rowCount > 0 {
                y += CGFloat(rowCount) * metrics.cellHeight
                    + CGFloat(rowCount - 1) * metrics.rowSpacing
            }
            if index < sections.count - 1 { y += Self.sectionGap }
        }
        self.headers = headers
        self.cells = cells
        self.allAppsTop = allAppsTop
        self.height = y + metrics.verticalInset
    }

    /// The header's frame for a section, nil when it draws none.
    func headerFrame(_ section: DeckSection) -> CGRect? { headers[section.kind] }

    func cellFrame(section: Int, index: Int) -> CGRect? {
        guard cells.indices.contains(section), cells[section].indices.contains(index) else { return nil }
        return cells[section][index]
    }
}

/// [DECK-26] The page's one layout pass: it computes the block once and places
/// every section's header and cells from it. Sections are ranges of cells in
/// this single layout, never a fixed layout of their own.
struct DeckStartLayout: Layout {
    var zoom: CGFloat = 1
    var sections: [DeckSection] = []

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let page = DeckPageLayout(width: width, metrics: DeckGridSize(zoom: zoom), sections: sections)
        return CGSize(width: width, height: page.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let page = DeckPageLayout(width: bounds.width, metrics: DeckGridSize(zoom: zoom), sections: sections)
        var index = 0
        for (sectionIndex, section) in sections.enumerated() {
            if let header = page.headerFrame(section), index < subviews.count {
                subviews[index].place(at: CGPoint(x: bounds.minX + header.minX,
                                                  y: bounds.minY + header.minY),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: header.width, height: header.height))
                index += 1
            }
            for frame in page.cells[sectionIndex] where index < subviews.count {
                subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX,
                                                  y: bounds.minY + frame.minY),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: frame.width, height: frame.height))
                index += 1
            }
        }
        MainActor.assumeIsolated { DeckGridProbe.reportSections(page) }
    }
}

/// [DECK-26] A section's header: the prototype's 11 pt semibold secondary
/// label, placed at the grid's leading edge by `DeckStartLayout`.
struct DeckSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// [DECK-28] The pins this Mac keeps for one phone. The Deck never writes to
/// the phone: the list is a stored preference per device, in pin order, at most
/// eight. A pin whose app the phone no longer lists is dropped silently.
struct DeckPins: Equatable {
    private(set) var pkgs: [String]

    init(_ pkgs: [String] = []) {
        var seen = Set<String>()
        var kept: [String] = []
        for pkg in pkgs where !pkg.isEmpty && seen.insert(pkg).inserted {
            kept.append(pkg)
        }
        if kept.count > DeckPage.pinnedLimit {
            kept.removeLast(kept.count - DeckPage.pinnedLimit)
        }
        self.pkgs = kept
    }

    var isFull: Bool { pkgs.count >= DeckPage.pinnedLimit }
    func contains(_ pkg: String) -> Bool { pkgs.contains(pkg) }

    /// Pin an app at the end of the list. A full list stays as it is (the ninth
    /// pin's menu item is disabled before this is called).
    func pinning(_ pkg: String) -> DeckPins {
        guard !pkg.isEmpty, !contains(pkg), !isFull else { return self }
        return DeckPins(pkgs + [pkg])
    }

    func unpinning(_ pkg: String) -> DeckPins {
        DeckPins(pkgs.filter { $0 != pkg })
    }

    /// Drop the pins of apps the phone no longer lists, keeping the others'
    /// order. Nothing is shown about a dropped pin: the app is gone.
    func pruning(_ installed: Set<String>) -> DeckPins {
        DeckPins(pkgs.filter { installed.contains($0) })
    }
}

/// [DECK-28] The pins' one store: the profile's defaults, one list per phone.
enum DeckPinStore {
    static func key(deviceId: String) -> String { "deckPins.\(deviceId)" }

    static func load(deviceId: String, from defaults: UserDefaults) -> DeckPins {
        guard !deviceId.isEmpty else { return DeckPins() }
        return DeckPins(defaults.stringArray(forKey: key(deviceId: deviceId)) ?? [])
    }

    static func save(_ pins: DeckPins, deviceId: String, to defaults: UserDefaults) {
        guard !deviceId.isEmpty else { return }
        defaults.set(pins.pkgs, forKey: key(deviceId: deviceId))
    }
}

/// [DECK-31] The Deck's title: the phone's name with one phone, a menu of the
/// remembered phones with two or more. Pure, so the rule is pinned without a
/// window; the view draws the rows.
enum DeckTitle {
    struct Row: Equatable {
        let id: String
        let name: String
        let checked: Bool
    }

    static func isMenu(phoneCount: Int) -> Bool { phoneCount > 1 }

    /// One row per remembered phone, the one in use checked.
    static func rows(_ phones: [(id: String, name: String)], inUse: String?) -> [Row] {
        phones.map { Row(id: $0.id, name: $0.name, checked: $0.id == inUse) }
    }
}
