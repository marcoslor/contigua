#if POCKETDECK_DIRECT
import Foundation

// The helper's network stack and daemon land in the commits that follow; the
// product exists now so the product name, the define and the public gate are
// real from the first commit (docs/design/direct-link.md §1.1).
FileHandle.standardError.write(Data("pocketdeck-directd: no network stack yet\n".utf8))
exit(2)
#else
import Foundation

let name = ["POCKETDECK", "DIRECT"].joined(separator: "_")
FileHandle.standardError.write(Data("built without \(name)\n".utf8))
exit(2)
#endif
