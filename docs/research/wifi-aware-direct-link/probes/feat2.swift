import Foundation
let h = dlopen("/System/Library/Frameworks/WiFiAware.framework/Versions/A/WiFiAware", RTLD_NOW)!
typealias PtrGetter = @convention(c) () -> UnsafeRawPointer
let p = dlsym(h, "$s9WiFiAware14WACapabilitiesV17supportedFeaturesShyAC7FeatureOGvgZ")!
let s = unsafeBitCast(p, to: PtrGetter.self)()
let empty = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_swiftEmptySetSingleton")!
print("returned", s, "emptySingleton", empty, s == UnsafeRawPointer(empty) ? "→ EMPTY" : "→ NOT the empty set")
print("words", (0..<6).map { String(format: "%llx", s.load(fromByteOffset: $0 * 8, as: UInt64.self)) })
