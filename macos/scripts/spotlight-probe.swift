// Standalone CoreSpotlight probe: index one item under a unique title, ask for
// it back through CSSearchQuery (and, optionally, mdfind), then delete it and
// print PASS or FAIL with the error chain.
//
//   swift macos/scripts/spotlight-probe.swift [options]
//
// The options exist only to bisect the cause, one factor at a time:
//   --index NAME      a named index (default: CSSearchableIndex.default())
//   --minimal         only a title on the item (default: the app's full set)
//   --content-url P   add the content URL the app's items omit
//   --mdfind          also look the title up with /usr/bin/mdfind
//   --timeout SECS    how long to wait for the item to be queryable (default 30)
//   --keep            leave the item indexed (default: delete it afterwards)
//   --query-only T    skip indexing and only query for the title T
//   --query-raw Q     skip indexing and only run the raw query string Q
//
// Exit codes: 0 PASS, 1 FAIL.
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

struct Options {
    var indexName: String? = nil
    var minimal = false
    var contentURL: String? = nil
    var useMdfind = false
    var timeout: TimeInterval = 30
    var keep = false
    var queryOnly: String? = nil
    var queryRaw: String? = nil
}

enum ProbeError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let text): return text
        }
    }
}

let probeRun = UUID().uuidString.prefix(8)
let probeTitle = "Contigua Spotlight Probe \(probeRun)"

func parseOptions() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        func value(_ name: String) throws -> String {
            guard !args.isEmpty else { throw ProbeError.usage("\(name) needs a value") }
            return args.removeFirst()
        }
        switch arg {
        case "--index": options.indexName = try value(arg)
        case "--minimal": options.minimal = true
        case "--content-url": options.contentURL = try value(arg)
        case "--mdfind": options.useMdfind = true
        case "--keep": options.keep = true
        case "--query-only": options.queryOnly = try value(arg)
        case "--query-raw": options.queryRaw = try value(arg)
        case "--timeout":
            let raw = try value(arg)
            guard let seconds = TimeInterval(raw) else { throw ProbeError.usage("bad --timeout \(raw)") }
            options.timeout = seconds
        case "--help", "-h":
            print("usage: spotlight-probe.swift [--index NAME] [--minimal] [--content-url PATH] [--mdfind] [--timeout SECS] [--keep] [--query-only TITLE]")
            exit(0)
        default:
            throw ProbeError.usage("unknown option \(arg)")
        }
    }
    return options
}

/// The app's log shows only the outermost domain; the cause is in the
/// underlying chain, so every level is printed.
func errorChain(_ error: Error) -> String {
    var parts: [String] = []
    var current: NSError? = error as NSError
    var depth = 0
    while let error = current, depth < 6 {
        parts.append("\(error.domain) \(error.code) \"\(error.localizedDescription)\"")
        current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        depth += 1
    }
    return parts.joined(separator: " <- ")
}

func makeIndex(_ options: Options) -> CSSearchableIndex {
    guard let name = options.indexName else { return CSSearchableIndex.default() }
    return CSSearchableIndex(name: name)
}

func makeItem(_ options: Options) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .application)
    attributes.title = probeTitle
    attributes.displayName = probeTitle
    attributes.contentDescription = "Android app on ProbePhone"
    if !options.minimal {
        attributes.keywords = ["ContiguaProbe", "probe.pkg", "ProbePhone", "Android"]
        if let path = options.contentURL {
            attributes.contentURL = URL(fileURLWithPath: path)
        }
    }
    return CSSearchableItem(uniqueIdentifier: "probe/\(probeRun)",
                            domainIdentifier: "probe.\(probeRun)",
                            attributeSet: attributes)
}

/// Completion handlers run on a private queue, so a semaphore is enough and
/// the process needs no running run loop.
func indexItem(_ index: CSSearchableIndex, _ item: CSSearchableItem) -> Error? {
    let done = DispatchSemaphore(value: 0)
    var failure: Error?
    index.indexSearchableItems([item]) { error in
        failure = error
        done.signal()
    }
    if done.wait(timeout: .now() + 30) == .timedOut {
        return NSError(domain: "spotlight-probe", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: "indexSearchableItems did not call back in 30 s"])
    }
    return failure
}

func deleteDomain(_ index: CSSearchableIndex, _ domain: String) {
    let done = DispatchSemaphore(value: 0)
    index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in done.signal() }
    _ = done.wait(timeout: .now() + 15)
}

enum Outcome {
    case found
    case missed
    case failed(String)
}

func describe(_ outcome: Outcome) -> String {
    switch outcome {
    case .found: return "found"
    case .missed: return "not found within the timeout"
    case .failed(let text): return text
    }
}

/// One CSSearchQuery for the exact title; the first completion wins.
var lastFoundIdentifiers: [String] = []

func searchOnce(queryString: String) -> Outcome {
    let context = CSSearchQueryContext()
    context.fetchAttributes = ["title"]
    let query = CSSearchQuery(queryString: queryString, queryContext: context)
    let done = DispatchSemaphore(value: 0)
    var outcome = Outcome.missed
    query.foundItemsHandler = { items in
        if !items.isEmpty {
            outcome = .found
            lastFoundIdentifiers.append(contentsOf: items.compactMap(\.uniqueIdentifier))
        }
    }
    query.completionHandler = { error in
        if let error { outcome = .failed(errorChain(error)) }
        done.signal()
    }
    query.start()
    if done.wait(timeout: .now() + 15) == .timedOut {
        query.cancel()
        return .failed("CSSearchQuery did not complete in 15 s")
    }
    return outcome
}

func waitForItem(queryString: String, timeout: TimeInterval) -> Outcome {
    let deadline = Date().addingTimeInterval(timeout)
    var last = Outcome.missed
    repeat {
        last = searchOnce(queryString: queryString)
        if case .found = last { return last }
        Thread.sleep(forTimeInterval: 2)
    } while Date() < deadline
    return last
}

func mdfindLookup(title: String) -> Outcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    process.arguments = ["kMDItemTitle == \"\(title)\""]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
    } catch {
        return .failed("mdfind did not start: \(errorChain(error))")
    }
    let deadline = Date().addingTimeInterval(30)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
    if process.isRunning {
        process.terminate()
        return .failed("mdfind did not finish in 30 s")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return out.isEmpty ? .missed : .found
}

func main() -> Int32 {
    let options: Options
    do {
        options = try parseOptions()
    } catch {
        FileHandle.standardError.write(Data("spotlight-probe: \(error)\n".utf8))
        return 1
    }
    print("probe \(probeRun): index=\(options.indexName ?? "default") minimal=\(options.minimal) bundle=\(Bundle.main.bundleIdentifier ?? "none")")

    if let raw = options.queryRaw {
        let outcome = waitForItem(queryString: raw, timeout: options.timeout)
        print("query \(raw): \(describe(outcome)) items=\(lastFoundIdentifiers.count) ids=\(lastFoundIdentifiers.prefix(5).joined(separator: ","))")
        if case .found = outcome { return 0 }
        return 1
    }
    if let title = options.queryOnly {
        let outcome = waitForItem(queryString: "title == \"\(title)\"c", timeout: options.timeout)
        print("query \"\(title)\": \(describe(outcome))")
        if options.useMdfind { print("mdfind: \(describe(mdfindLookup(title: title)))") }
        if case .found = outcome { return 0 }
        return 1
    }

    let index = makeIndex(options)
    let item = makeItem(options)
    if let error = indexItem(index, item) {
        print("FAIL indexSearchableItems: \(errorChain(error))")
        return 1
    }
    print("indexed without error")
    let outcome = waitForItem(queryString: "title == \"\(probeTitle)\"c", timeout: options.timeout)
    let byMdfind = options.useMdfind ? mdfindLookup(title: probeTitle) : nil
    if !options.keep { deleteDomain(index, item.domainIdentifier ?? "") }
    if let byMdfind { print("mdfind: \(describe(byMdfind))") }
    switch outcome {
    case .found:
        print("PASS CSSearchQuery found the item")
        return 0
    case .missed, .failed:
        print("FAIL \(describe(outcome))")
        return 1
    }
}

exit(main())
