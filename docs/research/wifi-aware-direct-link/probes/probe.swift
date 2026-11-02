import Foundation
let path = "/System/Library/Frameworks/WiFiAware.framework/Versions/A/WiFiAware"
guard let h = dlopen(path, RTLD_NOW) else { print("dlopen failed"); exit(1) }
typealias IntGetter = @convention(c) () -> Int
for name in ["maximumConnectableDevices", "maximumPublishableServices", "maximumSubscribableServices"] {
    let sym = "$s9WiFiAware14WACapabilitiesV\(name.count)\(name)SivgZ"
    guard let p = dlsym(h, sym) else { print(name, "no symbol"); continue }
    let f = unsafeBitCast(p, to: IntGetter.self)
    print(name, f())
}
