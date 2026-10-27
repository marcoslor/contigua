// The menu bar panel's secondary-click prototype (`--debug-proto
// panelmenu=M1|M2|M3`, test builds only): three real renders of moving
// Settings…/Quit from the panel's footer to a right-click menu, for a review
// that ships nothing yet. Without the flag the panel is exactly as it is
// today, so "no prototype" is a real choice and not a fourth case.

enum PanelMenuPrototype: String, CaseIterable {
    /// The right-click menu only: the footer's Settings…/Quit rows go.
    case m1 = "M1"
    /// The right-click menu and a gear at the panel's top-right that opens the
    /// same menu; the footer goes.
    case m2 = "M2"
    /// The right-click menu and today's footer.
    case m3 = "M3"

    /// The prototype this run was started with, or nil without the flag.
    @MainActor static var current: PanelMenuPrototype?

    /// The panel keeps Settings…/Quit in its footer.
    var showsFooter: Bool { self == .m3 }

    /// The panel carries the gear button that opens the same menu.
    var showsGear: Bool { self == .m2 }

    /// `panelmenu=M1`: the one key this flag reads. Another key or value
    /// leaves the panel alone, like any other unknown debug flag.
    static func parse(_ value: String?) -> PanelMenuPrototype? {
        guard let value else { return nil }
        let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "panelmenu" else { return nil }
        return PanelMenuPrototype(rawValue: parts[1])
    }
}
