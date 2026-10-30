import Foundation
import ObjectiveC
_ = dlopen("/System/Library/Frameworks/WiFiAware.framework/Versions/A/WiFiAware", RTLD_NOW)
_ = dlopen("/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/WiFiPeerToPeer", RTLD_NOW)
var n: UInt32 = 0
let all = objc_copyClassList(&n)!
var names: [String] = []
for i in 0..<Int(n) { let s = String(cString: class_getName(all[i])); if s.hasPrefix("WiFiAware") || s.hasPrefix("WiFiP2P") { names.append(s) } }
print(names.sorted().joined(separator: "\n"))
