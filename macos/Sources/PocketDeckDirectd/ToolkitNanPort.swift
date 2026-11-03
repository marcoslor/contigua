#if POCKETDECK_DIRECT
import Darwin
import Foundation
import ObjectiveC
import PocketDeckDirectCore

/// §2.2's real adapter: `dlopen` the private toolkit, `NSClassFromString` the
/// classes, `objc_msgSend` (as IMP function pointers) the calls, and a
/// forwarding delegate so a private selector Apple renames does not stop
/// discovery. Thin on purpose: this file is the whole runtime surface, and
/// K2 only proves it builds and that its names are still the proof's names.
/// Nothing here may be called in a test.
final class ToolkitNanPort: NanPort {
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer"

    /// The selectors `sub.m` pins on the toolkit's classes.
    static let outgoingSelectors = [
        "initWithServiceName:",
        "setAuthenticationType:",
        "initWithConfiguration:",
        "setDelegate:",
        "start",
        "stop",
        "initWithDiscoveryResult:serviceType:serviceSpecificInfo:passphrase:",
        "initWithDiscoveryResult:serviceType:serviceSpecificInfo:",
    ]

    /// `sub.m` forwards every selector with one of these prefixes.
    static let callbackPrefixes = ["subscri", "dataSession", "datapath"]

    /// `proto.m`'s protocol lookups. Absent at run time means the forwarding
    /// delegate's prefixes are the only pin, which is the fallback §2.2 asks
    /// for; the real names are confirmed in the reviewer's run.
    static let protocolNames = ["WiFiAwareSubscriberDelegate",
                                "WiFiAwareDataSessionDelegate"]

    /// Both probes used service type 1 (§2.2 step 4).
    static let serviceType = 1

    /// True once an instance has dlopen'd the framework. Tests assert false.
    static private(set) var loaded = false

    var onDiscovery: ((NanDiscovery) -> Void)?
    var onReport: ((NanDataSessionReport) -> Void)?

    private let log: (String) -> Void
    private var handle: UnsafeMutableRawPointer?
    private var subscriber: AnyObject?
    private var subscriberDelegate: NanForwardingDelegate?
    private var session: AnyObject?
    private var sessionDelegate: NanForwardingDelegate?
    private var discoveries: [Int: AnyObject] = [:]
    private var nextToken = 1

    init?(log: @escaping (String) -> Void = { _ in }) {
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else { return nil }
        guard NSClassFromString("WiFiAwareSubscribeConfiguration") != nil,
              NSClassFromString("WiFiAwareSubscriber") != nil,
              NSClassFromString("WiFiAwareDataSession") != nil else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.log = log
        Self.loaded = true
    }

    deinit {
        unsubscribe()
        stopDataSession()
        if let handle { dlclose(handle) }
    }

    // MARK: NanPort

    /// The SSI never reaches the toolkit: §6 matches it in the helper after
    /// discovery, and the subscribe config carries no service-specific info.
    func subscribe(service: String, windows: [NanSsi]) throws {
        unsubscribe()
        guard let config = Self.make("WiFiAwareSubscribeConfiguration",
                                     initSelector: "initWithServiceName:",
                                     argument: service as AnyObject) else {
            throw NanPortError.failed
        }
        Self.sendLong(config, "setAuthenticationType:", 0)
        guard let subscriber = Self.make("WiFiAwareSubscriber",
                                         initSelector: "initWithConfiguration:",
                                         argument: config) else {
            throw NanPortError.failed
        }
        let delegate = NanForwardingDelegate(prefixes: Self.callbackPrefixes)
        delegate.pinned = Self.pinnedSelectors(Self.protocolNames[0])
        delegate.onCallback = { [weak self] name, objects in
            self?.subscriberEvent(name, objects)
        }
        Self.sendObject(subscriber, "setDelegate:", delegate)
        self.subscriber = subscriber
        self.subscriberDelegate = delegate
        Self.send0(subscriber, "start")
        log("toolkit: subscribed windows=\(windows.count)")
    }

    func updateWindows(_ windows: [NanSsi]) throws {
        // Nothing to tell the radio: the match happens in NanSessionMachine.
    }

    func startDataSession(token: Int, passphrase: String) throws {
        guard let discovery = discoveries[token] else {
            throw NanPortError.failed
        }
        guard let session = Self.makeSession(discovery: discovery,
                                             serviceType: Self.serviceType,
                                             passphrase: passphrase as AnyObject) else {
            throw NanPortError.failed
        }
        let delegate = NanForwardingDelegate(prefixes: Self.callbackPrefixes)
        delegate.pinned = Self.pinnedSelectors(Self.protocolNames[1])
        delegate.onCallback = { [weak self] name, objects in
            self?.sessionEvent(name, objects)
        }
        Self.sendObject(session, "setDelegate:", delegate)
        self.session = session
        self.sessionDelegate = delegate
        Self.send0(session, "start")
        log("toolkit: data session starting")
    }

    func stopDataSession() {
        if let session { Self.send0(session, "stop") }
        session = nil
        sessionDelegate = nil
    }

    func unsubscribe() {
        if let subscriber { Self.send0(subscriber, "stop") }
        subscriber = nil
        subscriberDelegate = nil
        discoveries.removeAll()
    }

    // MARK: callbacks

    private func subscriberEvent(_ name: String, _ objects: [AnyObject]) {
        for object in objects where Self.className(of: object).contains("WiFiAwareDiscoveryResult") {
            guard let ssi = Self.ssi(from: object) else {
                log("toolkit: discovery without service-specific info")
                return
            }
            let token = nextToken
            nextToken += 1
            discoveries[token] = object
            onDiscovery?(NanDiscovery(token: token, ssi: ssi))
            return
        }
    }

    private func sessionEvent(_ name: String, _ objects: [AnyObject]) {
        let lower = name.lowercased()
        if lower.contains("fail") {
            onReport?(.failed(.ndpRefused))
            return
        }
        if lower.contains("lost") || lower.contains("ended") || lower.contains("invalid") {
            onReport?(.lost)
            return
        }
        for object in objects {
            if let peer = Self.peer(from: object) {
                onReport?(.up(mac: peer.mac, linkLocal: peer.linkLocal))
                return
            }
        }
        if lower.contains("start") {
            onReport?(.starting)
        }
    }

    // MARK: the toolkit's objects

    private static func make(_ className: String, initSelector: String,
                             argument: AnyObject) -> AnyObject? {
        guard let cls = NSClassFromString(className) else { return nil }
        let selector = NSSelectorFromString(initSelector)
        guard let method = class_getInstanceMethod(cls, selector),
              let raw = allocate(cls) else { return nil }
        typealias Init = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject)
            -> UnsafeMutableRawPointer?
        guard let result = unsafeBitCast(method_getImplementation(method), to: Init.self)(
            raw, selector, argument) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(result).takeRetainedValue()
    }

    private static func makeSession(discovery: AnyObject, serviceType: Int,
                                    passphrase: AnyObject) -> AnyObject? {
        guard let cls = NSClassFromString("WiFiAwareDataSession") else { return nil }
        let selector = NSSelectorFromString(
            "initWithDiscoveryResult:serviceType:serviceSpecificInfo:passphrase:")
        guard let method = class_getInstanceMethod(cls, selector),
              let raw = allocate(cls) else { return nil }
        typealias Init = @convention(c) (UnsafeMutableRawPointer, Selector,
                                         AnyObject, Int, AnyObject?, AnyObject?)
            -> UnsafeMutableRawPointer?
        guard let result = unsafeBitCast(method_getImplementation(method), to: Init.self)(
            raw, selector, discovery, serviceType, nil, passphrase) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(result).takeRetainedValue()
    }

    private static func allocate(_ cls: AnyClass) -> UnsafeMutableRawPointer? {
        let selector = NSSelectorFromString("alloc")
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Alloc = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        return unsafeBitCast(method_getImplementation(method), to: Alloc.self)(
            cls as AnyObject, selector)
    }

    private static func send0(_ object: AnyObject, _ name: String) {
        guard let imp = instanceIMP(object, name) else { return }
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(imp, to: Call.self)(object, NSSelectorFromString(name))
    }

    private static func sendObject(_ object: AnyObject, _ name: String,
                                   _ argument: AnyObject?) {
        guard let imp = instanceIMP(object, name) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(imp, to: Call.self)(object, NSSelectorFromString(name), argument)
    }

    private static func sendLong(_ object: AnyObject, _ name: String, _ value: Int) {
        guard let imp = instanceIMP(object, name) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(imp, to: Call.self)(object, NSSelectorFromString(name), value)
    }

    private static func property(_ object: AnyObject, _ name: String) -> AnyObject? {
        guard let imp = instanceIMP(object, name) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> AnyObject?
        return unsafeBitCast(imp, to: Call.self)(object, NSSelectorFromString(name))
    }

    fileprivate static func instanceIMP(_ object: AnyObject, _ name: String) -> IMP? {
        let selector = NSSelectorFromString(name)
        guard let cls = object_getClass(object),
              let method = class_getInstanceMethod(cls, selector) else { return nil }
        return method_getImplementation(method)
    }

    private static func className(of object: AnyObject) -> String {
        guard let cls = object_getClass(object) else { return "" }
        return NSStringFromClass(cls)
    }

    private static func ssi(from result: AnyObject) -> NanSsi? {
        for key in ["serviceSpecificInfo", "serviceSpecificInfoData"] {
            guard let value = property(result, key) else { continue }
            if let data = value as? Data { return NanSsi(Array(data)) }
            if let text = value as? String,
               let data = Data(base64Encoded: text) {
                return NanSsi(Array(data))
            }
        }
        return nil
    }

    /// The data-session report's peer, wherever the toolkit put it: the
    /// state itself, or one of its nested info objects (§2.2 step 5).
    private static func peer(from object: AnyObject) -> (mac: String, linkLocal: String)? {
        var candidates = [object]
        for key in ["ndiInfo", "sessionInfo", "state", "dataPathState"] {
            if let nested = property(object, key) { candidates.append(nested) }
        }
        for candidate in candidates {
            guard let mac = mac(from: candidate),
                  let address = address(from: candidate),
                  isMAC(mac), IPv6Address.parse(address) != nil else { continue }
            return (mac, address)
        }
        return nil
    }

    private static func mac(from object: AnyObject) -> String? {
        for key in ["macAddress", "peerMacAddress", "mac"] {
            guard let value = property(object, key) else { continue }
            if let text = value as? String {
                let lower = text.lowercased()
                if isMAC(lower) { return lower }
            }
            if let data = value as? Data, data.count == 6 {
                return data.map { String(format: "%02x", $0) }.joined(separator: ":")
            }
        }
        return nil
    }

    private static func address(from object: AnyObject) -> String? {
        for key in ["linkLocalAddress", "ipv6Address", "peerAddress", "address",
                    "linkLocal"] {
            guard let value = property(object, key) else { continue }
            if let text = value as? String, IPv6Address.parse(text) != nil { return text }
            if let data = value as? Data, data.count == 16 {
                return IPv6Address.format(Array(data))
            }
        }
        return nil
    }

    /// `proto.m`'s pinning: the real callback selectors, when the protocol is
    /// registered. An empty set leaves the forwarding prefixes as the pin.
    private static func pinnedSelectors(_ name: String) -> Set<String> {
        guard let proto = objc_getProtocol(name) else { return [] }
        var names: Set<String> = []
        for required in [true, false] {
            var count: UInt32 = 0
            guard let list = protocol_copyMethodDescriptionList(proto, required, true,
                                                                &count) else { continue }
            defer { free(list) }
            for index in 0..<Int(count) {
                if let selector = list[index].name {
                    names.insert(NSStringFromSelector(selector))
                }
            }
        }
        return names
    }
}

/// Receives the delegate callbacks the private toolkit sends, without a
/// header: Swift cannot name `NSInvocation`, so `forwardInvocation:` and
/// `methodSignatureForSelector:` are added to this class with `class_addMethod`
/// and drive the invocation through the Objective-C runtime, as `sub.m` does.
final class NanForwardingDelegate: NSObject {
    private let prefixes: [String]
    var pinned: Set<String> = []
    var onCallback: ((String, [AnyObject]) -> Void)?

    private static let installed: Void = installForwarding()

    init(prefixes: [String]) {
        self.prefixes = prefixes
        super.init()
        _ = Self.installed
    }

    override func responds(to aSelector: Selector!) -> Bool {
        guard let aSelector else { return false }
        let name = NSStringFromSelector(aSelector)
        if prefixes.contains(where: { name.hasPrefix($0) }) || pinned.contains(name) {
            return true
        }
        return super.responds(to: aSelector)
    }

    fileprivate func receive(_ name: String, _ objects: [AnyObject]) {
        onCallback?(name, objects)
    }

    private static func installForwarding() -> Void {
        let cls: AnyClass = NanForwardingDelegate.self
        _ = class_addMethod(cls, NSSelectorFromString("forwardInvocation:"),
                            unsafeBitCast(nanForwardInvocation, to: IMP.self), "v@:@")
        _ = class_addMethod(cls, NSSelectorFromString("methodSignatureForSelector:"),
                            unsafeBitCast(nanMethodSignature, to: IMP.self), "@@::")
        return ()
    }

    fileprivate static func selectorName(of invocation: AnyObject) -> String? {
        let name = "selector"
        guard let imp = ToolkitNanPort.instanceIMP(invocation, name) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> Selector
        return NSStringFromSelector(unsafeBitCast(imp, to: Call.self)(
            invocation, NSSelectorFromString(name)))
    }

    fileprivate static func signature(of invocation: AnyObject) -> AnyObject? {
        let name = "methodSignature"
        guard let imp = ToolkitNanPort.instanceIMP(invocation, name) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> AnyObject?
        return unsafeBitCast(imp, to: Call.self)(invocation, NSSelectorFromString(name))
    }

    fileprivate static func numberOfArguments(in signature: AnyObject) -> Int? {
        let name = "numberOfArguments"
        guard let imp = ToolkitNanPort.instanceIMP(signature, name) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(imp, to: Call.self)(signature, NSSelectorFromString(name))
    }

    fileprivate static func getArgument(_ invocation: AnyObject,
                                    _ buffer: UnsafeMutableRawPointer, _ index: Int) {
        let name = "getArgument:atIndex:"
        guard let imp = ToolkitNanPort.instanceIMP(invocation, name) else { return }
        typealias Call = @convention(c) (AnyObject, Selector,
                                         UnsafeMutableRawPointer, Int) -> Void
        unsafeBitCast(imp, to: Call.self)(invocation, NSSelectorFromString(name),
                                          buffer, index)
    }

    fileprivate static func signature(for selector: Selector) -> AnyObject? {
        var types = "v@:"
        for character in String(cString: sel_getName(selector)) where character == ":" {
            types.append("@")
        }
        guard let cls = NSClassFromString("NSMethodSignature") else { return nil }
        let name = "signatureWithObjCTypes:"
        guard let method = class_getClassMethod(cls, NSSelectorFromString(name)) else {
            return nil
        }
        typealias Call = @convention(c) (AnyObject, Selector, UnsafePointer<CChar>)
            -> AnyObject?
        let imp = unsafeBitCast(method_getImplementation(method), to: Call.self)
        return types.withCString { imp(cls as AnyObject, NSSelectorFromString(name), $0) }
    }
}

private typealias ForwardIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
private typealias SignatureIMP = @convention(c) (AnyObject, Selector, Selector) -> AnyObject?
#endif

/// The two runtime entry points `installForwarding` registers. Top-level and
/// captureless, so they are C function pointers.
private let nanForwardInvocation: ForwardIMP = { object, _, invocation in
    guard let delegate = object as? NanForwardingDelegate,
          let signature = NanForwardingDelegate.signature(of: invocation),
          let count = NanForwardingDelegate.numberOfArguments(in: signature) else { return }
    var objects: [AnyObject] = []
    for index in 2..<count {
        var raw: UnsafeMutableRawPointer?
        NanForwardingDelegate.getArgument(invocation, &raw, index)
        if let raw, UInt(bitPattern: UnsafeRawPointer(raw)) > 0x1_0000 {
            objects.append(Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue())
        }
    }
    delegate.receive(NanForwardingDelegate.selectorName(of: invocation) ?? "callback",
                     objects)
}

private let nanMethodSignature: SignatureIMP = { _, _, selector in
    NanForwardingDelegate.signature(for: selector)
}
