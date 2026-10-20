// What this app bundle can do for Finder files (docs/design/files.md "Fixes
// 10-20"). `bundle.sh --with-files` adds two things: the App Group the bridge's
// socket lives in, and the File Provider extension that mounts it. A build with
// neither (`bundle.sh` default, `swift run`) must say so instead of offering a
// switch whose "Restart PocketDeck" could never help.

import Foundation

enum FilesBundleSupport {
    /// Where `bundle.sh --with-files` puts the extension.
    static let extensionPath = "Contents/PlugIns/Files.appex"

    static func group(_ info: [String: Any]?) -> String? {
        guard let value = info?[filesGroupInfoKey] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    static func supports(info: [String: Any]?, extensionExists: Bool) -> Bool {
        group(info) != nil && extensionExists
    }
}
