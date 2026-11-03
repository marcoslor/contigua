import Foundation
import ObjectiveC
_ = dlopen("/System/Library/Frameworks/WiFiAware.framework/Versions/A/WiFiAware", RTLD_NOW)
let cls = NSClassFromString("WiFiAwareDeviceCapabilities")! as AnyObject
let r = cls.perform(NSSelectorFromString("currentDeviceCapabilities"))
print("currentDeviceCapabilities:", r.map { String(describing: $0.takeUnretainedValue()) } ?? "nil")
