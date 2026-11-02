import Foundation
import Security
let task = SecTaskCreateFromSelf(nil)!
for e in ["com.apple.developer.wifi-aware", "com.apple.wifip2pd"] {
    var err: Unmanaged<CFError>?
    let v = SecTaskCopyValueForEntitlement(task, e as CFString, &err)
    print(e, v.map { "\($0)" } ?? "nil", err.map { "\($0.takeRetainedValue())" } ?? "")
}
