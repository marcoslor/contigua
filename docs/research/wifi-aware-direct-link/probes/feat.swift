import Foundation
let h = dlopen("/System/Library/Frameworks/WiFiAware.framework/Versions/A/WiFiAware", RTLD_NOW)!
typealias PtrGetter = @convention(c) () -> UnsafeRawPointer
let p = dlsym(h, "$s9WiFiAware14WACapabilitiesV17supportedFeaturesShyAC7FeatureOGvgZ")!
let storage = unsafeBitCast(p, to: PtrGetter.self)()
// native Set storage: isa, refcount, count
print("supportedFeatures count", storage.load(fromByteOffset: 16, as: Int.self))
