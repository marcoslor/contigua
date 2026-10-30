import Foundation
import ObjectiveC
_ = dlopen("/System/Library/Frameworks/WiFiAware.framework/Versions/A/WiFiAware", RTLD_NOW)
guard let cls: AnyClass = NSClassFromString("WiFiAwareDeviceCapabilities") else { print("no class"); exit(1) }
var info = Dl_info(); dladdr(unsafeBitCast(cls, to: UnsafeRawPointer.self), &info); print("image", String(cString: info.dli_fname))
func methods(_ c: AnyClass, _ tag: String) {
    var n: UInt32 = 0
    if let m = class_copyMethodList(c, &n) { for i in 0..<Int(n) { print(tag, NSStringFromSelector(method_getName(m[i]))) } }
}
methods(object_getClass(cls)!, "+"); methods(cls, "-")
var n: UInt32 = 0
if let p = class_copyPropertyList(cls, &n) { for i in 0..<Int(n) { print("prop", String(cString: property_getName(p[i])), String(cString: property_getAttributes(p[i])!)) } }
