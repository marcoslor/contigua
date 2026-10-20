// The pure half of phone files (FilesCore.swift): the bridge wire's incremental
// parser, the fs item → File Provider item mapping, the app-owned identifier
// map (and its persisted shape) and the error map. Nothing here touches
// FileProvider or a socket.

import Foundation
import XCTest
@testable import PocketDeck

final class FilesBridgeWireTests: XCTestCase {
    private func decode(_ data: Data) -> [BridgeEvent] {
        var decoder = BridgeDecoder()
        return decoder.feed([UInt8](data))
    }

    private func fileItem(_ name: String = "a.txt", id: String = "ino:6",
                          parent: String = ".rootContainer") -> FileItem {
        FilesMap.item(path: name, parentIdentifier: parent,
                      fs: FsItem(name: name, dir: false, size: 4, mtime: 5, ino: 6, etag: "aa"))
    }

    func testSignalsAreNotReplies() {
        let line = BridgeWire.signal(items: ["ino:10", FilesMap.rootIdentifier])
        XCTAssertEqual([.signal(items: ["ino:10", FilesMap.rootIdentifier])], decode(line))
    }

    func testRequestsRoundTrip() {
        let requests: [BridgeRequest] = [
            .hello(id: 1, version: filesBridgeVersion),
            .list(id: 2, item: "ino:10", page: "1000"),
            .list(id: 3, item: FilesMap.rootIdentifier, page: nil),
            .stat(id: 4, item: "ino:11"),
            .read(id: 5, item: "ino:12", offset: 10, length: 20, etag: "abcd"),
            .create(id: 6, request: BridgeCreate(parent: "ino:10", name: "new.txt",
                                                dir: false, size: 9, sha256: String(repeating: "a", count: 64))),
            .create(id: 7, request: BridgeCreate(parent: FilesMap.rootIdentifier, name: "Folder",
                                                dir: true, size: 0, sha256: nil)),
            .modify(id: 8, request: BridgeModify(item: "ino:13", base: "bb", content: true,
                                                name: nil, parent: nil, mtime: nil,
                                                size: 3, sha256: String(repeating: "c", count: 64))),
            .modify(id: 9, request: BridgeModify(item: "ino:13", base: "bb", content: false,
                                                name: "renamed.txt", parent: nil, mtime: nil,
                                                size: 0, sha256: nil)),
            .delete(id: 10, item: "ino:13", base: "bb", recursive: true),
            .watch(id: 11, items: ["ino:10", FilesMap.rootIdentifier], on: true),
            .watch(id: 12, items: ["ino:10"], on: false),
            .changes(id: 13, item: "ino:10", from: "g2.ino:10"),
            .anchor(id: 14, item: "ino:10"),
            .cancel(id: 5),
        ]
        for request in requests {
            XCTAssertEqual([.request(request)], decode(BridgeWire.line(request)),
                           "\(request)")
        }
    }

    func testRepliesRoundTrip() {
        let item = fileItem()
        let replies: [BridgeReply] = [
            .hello(id: 1, version: filesBridgeVersion, name: "Nicky", connected: true),
            .hello(id: 1, version: filesBridgeVersion, name: nil, connected: false),
            .items(id: 2, page: "40", items: [item, fileItem("b.txt", id: "ino:7")]),
            .items(id: 2, page: nil, items: []),
            .item(id: 3, item: item),
            .ready(id: 4),
            .ok(id: 5),
            .end(id: 6, size: 1024, sha256: "ff"),
            .error(id: 7, code: "fs_not_found"),
            .changes(id: 8, anchor: "g3.ino:10", items: [item],
                     deleted: ["ino:99"], expired: false),
            .changes(id: 9, anchor: "g0.ino:10", items: [], deleted: [], expired: true),
            .anchor(id: 10, anchor: "g0.ino:10"),
        ]
        for reply in replies {
            XCTAssertEqual([.reply(reply)], decode(BridgeWire.line(reply)), "\(reply)")
        }
    }

    func testAnItemCarriesEverythingTheExtensionNeeds() {
        let item = fileItem()
        guard case .reply(.item(_, let parsed)) = decode(BridgeWire.line(.item(id: 1, item: item))).first else {
            return XCTFail("no item reply")
        }
        XCTAssertEqual(item, parsed)
        XCTAssertEqual(item.contentVersion, parsed.contentVersion)
        XCTAssertEqual(item.metadataVersion, parsed.metadataVersion)
    }

    func testDataHeaderCarriesExactlyItsBytes() {
        var decoder = BridgeDecoder()
        var events = decoder.feed([UInt8](BridgeWire.dataHeader(id: 7, length: 3)))
        XCTAssertEqual([.dataHeader(id: 7, length: 3)], events)
        events = decoder.feed([1, 2, 3])
        XCTAssertEqual([.data(id: 7, bytes: [1, 2, 3])], events)
        // The stop byte is data, not a newline: a chunk may contain any byte.
        var tail = BridgeDecoder()
        tail.feed([UInt8](BridgeWire.dataHeader(id: 8, length: 2)))
        XCTAssertEqual([.data(id: 8, bytes: [0x0A, 0x00])], tail.feed([0x0A, 0x00]))
    }

    func testAChunkSplitAcrossReads() {
        let header = BridgeWire.dataHeader(id: 5, length: 6)
        let stream = [UInt8](header) + [10, 20, 30, 40, 50, 60]
            + [UInt8](BridgeWire.line(.end(id: 5, size: 6, sha256: "x")))
        var decoder = BridgeDecoder()
        var events: [BridgeEvent] = []
        // Header half a line, then the rest, then the bytes in three pieces.
        let cuts = [3, header.count - 3, 2, 1, 3]
        var index = 0
        for size in cuts {
            events += decoder.feed(Array(stream[index..<min(index + size, stream.count)]))
            index += size
        }
        events += decoder.feed(Array(stream[index...]))
        XCTAssertEqual([
            .dataHeader(id: 5, length: 6),
            .data(id: 5, bytes: [10, 20, 30, 40, 50, 60]),
            .reply(.end(id: 5, size: 6, sha256: "x")),
        ], events)
    }

    func testOneByteAtATime() {
        let stream = [UInt8](BridgeWire.line(.list(id: 9, item: "ino:1", page: nil)))
            + [UInt8](BridgeWire.dataHeader(id: 9, length: 2)) + [7, 8]
        var decoder = BridgeDecoder()
        var events: [BridgeEvent] = []
        for byte in stream {
            events += decoder.feed([byte])
        }
        XCTAssertEqual([
            .request(.list(id: 9, item: "ino:1", page: nil)),
            .dataHeader(id: 9, length: 2),
            .data(id: 9, bytes: [7, 8]),
        ], events)
    }

    func testAnOversizedLineIsRefusedAndBreaksTheStream() {
        var decoder = BridgeDecoder()
        let junk = [UInt8](repeating: 0x41, count: BridgeWire.maxLineBytes + 1)
        XCTAssertEqual([.invalid("line_too_long")], decoder.feed(junk))
        XCTAssertTrue(decoder.broken)
        // Nothing more is parsed: the caller closes the connection.
        XCTAssertEqual([], decoder.feed([UInt8](BridgeWire.line(.cancel(id: 1)))))
    }

    func testAListingPageIsAllowedToBeOneLargeLine() {
        // 1000 items is one `items` reply; the request cap must not clip it.
        let items = (0..<1000).map { index in
            FilesMap.item(path: "file-\(index)-0123456789.txt", parentIdentifier: "ino:1",
                          fs: FsItem(name: "file-\(index)-0123456789.txt", dir: false, size: index,
                                     mtime: 1_700_000_000_000, ino: index + 1, etag: "etag-\(index)"))
        }
        let line = BridgeWire.line(.items(id: 3, page: "1000", items: items))
        XCTAssertGreaterThan(line.count, BridgeWire.maxLineBytes)
        var reply = BridgeDecoder(maxLineBytes: BridgeWire.maxReplyLineBytes)
        let events = reply.feed([UInt8](line))
        guard case .reply(.items(let id, let page, let parsed)) = events.first else {
            return XCTFail("no items reply: \(events)")
        }
        XCTAssertEqual(3, id)
        XCTAssertEqual("1000", page)
        XCTAssertEqual(1000, parsed.count)
        XCTAssertFalse(reply.broken)
        // The same line on a request channel is refused.
        var request = BridgeDecoder()
        XCTAssertEqual([.invalid("line_too_long")], request.feed([UInt8](line)))
    }

    func testMalformedLinesBecomeInvalidWithoutTheirContents() {
        XCTAssertEqual([.invalid("bad_json")], decode(Data("not json\n".utf8)))
        XCTAssertEqual([.invalid("bad_id")], decode(Data("{\"t\":\"list\"}\n".utf8)))
        XCTAssertEqual([.invalid("bad_id")], decode(Data("{\"t\":\"cancel\",\"id\":0}\n".utf8)))
        XCTAssertEqual([.invalid("unknown_type")], decode(Data("{\"t\":\"wat\",\"id\":1}\n".utf8)))
        XCTAssertEqual([.invalid("bad_request")], decode(Data("{\"t\":\"list\",\"id\":1}\n".utf8)))
        XCTAssertEqual([.invalid("bad_request")], decode(Data("{\"t\":\"create\",\"id\":1}\n".utf8)))
        XCTAssertEqual([.invalid("bad_len")], decode(Data("{\"t\":\"data\",\"id\":1,\"len\":-1}\n".utf8)))
    }
}

final class FilesItemMappingTests: XCTestCase {
    private func fs(_ name: String, dir: Bool = false, size: Int = 0, ino: Int = 42,
                    mtime: Int = 1_700_000_000_000, etag: String = "0123456789abcdef0123456789abcdef") -> FsItem {
        FsItem(name: name, dir: dir, size: size, mtime: mtime, ino: ino, etag: etag)
    }

    func testAFileMapsSizeDatesTypeAndVersions() {
        let item = FilesMap.item(path: "DCIM/photo.jpg", parentIdentifier: "ino:7",
                                 fs: fs("photo.jpg", size: 1234, ino: 99, mtime: 1_700_000_001_500))
        XCTAssertEqual("ino:99", item.identifier)
        XCTAssertEqual("ino:7", item.parentIdentifier)
        XCTAssertEqual("photo.jpg", item.name)
        XCTAssertEqual(1234, item.size)
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(Date(timeIntervalSince1970: 1_700_000_001.5), item.modificationDate)
        XCTAssertEqual("public.jpeg", item.contentTypeIdentifier)
        XCTAssertEqual(Data("0123456789abcdef0123456789abcdef".utf8), item.contentVersion)
        XCTAssertEqual(32, item.metadataVersion.count)
    }

    func testTextAndFolderTypes() {
        XCTAssertEqual("public.plain-text", FilesMap.item(path: "notes.txt", parentIdentifier: "ino:1",
                                                          fs: fs("notes.txt")).contentTypeIdentifier)
        XCTAssertEqual("public.folder", FilesMap.item(path: "DCIM", parentIdentifier: ".rootContainer",
                                                       fs: fs("DCIM", dir: true)).contentTypeIdentifier)
        XCTAssertEqual("public.data", FilesMap.item(path: "blob", parentIdentifier: "ino:1",
                                                     fs: fs("blob")).contentTypeIdentifier)
    }

    func testVersionsChangeWithTheEtag() {
        let first = FilesMap.item(path: "a.bin", parentIdentifier: "ino:1", fs: fs("a.bin", etag: "aa"))
        let second = FilesMap.item(path: "a.bin", parentIdentifier: "ino:1", fs: fs("a.bin", etag: "bb"))
        XCTAssertNotEqual(first.contentVersion, second.contentVersion)
        XCTAssertEqual(first.metadataVersion, second.metadataVersion)
        // A metadata change moves the metadata version but not the content one.
        let renamed = FilesMap.item(path: "b.bin", parentIdentifier: "ino:1", fs: fs("b.bin", etag: "aa"))
        XCTAssertEqual(first.contentVersion, renamed.contentVersion)
        XCTAssertNotEqual(first.metadataVersion, renamed.metadataVersion)
    }

    func testTheIdentifierIsTheInoSoARenameKeepsIt() {
        XCTAssertEqual("ino:12", FilesMap.identifier(path: "x", ino: 12))
        XCTAssertEqual("ino:12", FilesMap.identifier(path: "renamed", ino: 12))
        XCTAssertEqual(".rootContainer", FilesMap.identifier(path: "", ino: 0))
        // A phone that reports no ino falls back to the path, one opaque token.
        XCTAssertEqual("path:DCIM%2Fnotes.txt",
                       FilesMap.identifier(path: "DCIM/notes.txt", ino: 0))
        XCTAssertEqual("DCIM/notes.txt",
                       FilesMap.path(fromIdentifier: "path:DCIM%2Fnotes.txt"))
        XCTAssertEqual("", FilesMap.path(fromIdentifier: FilesMap.rootIdentifier))
        // An ino identifier resolves only through the app's map.
        XCTAssertNil(FilesMap.path(fromIdentifier: "ino:99"))
        XCTAssertNil(FilesMap.path(fromIdentifier: "something-else"))
    }
}

final class FilesIdMapTests: XCTestCase {
    private func fs(_ name: String, dir: Bool = false, ino: Int, etag: String = "e") -> FsItem {
        FsItem(name: name, dir: dir, size: 0, mtime: 1, ino: ino, etag: etag)
    }

    func testAListingFillsTheMapBothWaysWithItsParents() {
        var map = FilesIdMap()
        let items = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                               items: [fs("DCIM", dir: true, ino: 10), fs("notes.txt", ino: 11)])
        XCTAssertEqual(["ino:10", "ino:11"], items.map(\.identifier))
        XCTAssertEqual("DCIM", map.path(for: "ino:10"))
        XCTAssertEqual("notes.txt", map.path(for: "ino:11"))
        XCTAssertEqual("ino:11", map.identifier(for: "notes.txt"))
        XCTAssertEqual("", map.path(for: FilesMap.rootIdentifier))
        XCTAssertEqual(FilesMap.rootIdentifier, map.parent(for: "ino:10"))
    }

    func testNestedPathsAndSubtreeInvalidation() {
        var map = FilesIdMap()
        map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                   items: [fs("DCIM", dir: true, ino: 10)])
        _ = map.insert(childrenOf: "DCIM", parentIdentifier: "ino:10",
                       items: [fs("Camera", dir: true, ino: 20)])
        _ = map.insert(childrenOf: "DCIM/Camera", parentIdentifier: "ino:20",
                       items: [fs("a.jpg", ino: 21), fs("b.jpg", ino: 22)])
        XCTAssertEqual("DCIM/Camera/a.jpg", map.path(for: "ino:21"))
        XCTAssertEqual("ino:20", map.parent(for: "ino:21"))
        map.invalidate(subtree: "DCIM")
        XCTAssertNil(map.path(for: "ino:10"))
        XCTAssertNil(map.path(for: "ino:20"))
        XCTAssertNil(map.path(for: "ino:21"))
        XCTAssertNil(map.identifier(for: "DCIM/Camera/a.jpg"))
    }

    func testARenameKeepsTheIdentifier() {
        var map = FilesIdMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("old.txt", ino: 30)])
        map.rename(identifier: "ino:30", to: "new.txt")
        XCTAssertEqual("new.txt", map.path(for: "ino:30"))
        XCTAssertNil(map.identifier(for: "old.txt"))
        XCTAssertEqual("ino:30", map.identifier(for: "new.txt"))
    }

    func testRenamingAFolderMovesItsChildren() {
        var map = FilesIdMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("old", dir: true, ino: 40)])
        _ = map.insert(childrenOf: "old", parentIdentifier: "ino:40", items: [fs("a.txt", ino: 41)])
        map.rename(identifier: "ino:40", to: "new")
        XCTAssertEqual("new/a.txt", map.path(for: "ino:41"))
        XCTAssertEqual("ino:41", map.identifier(for: "new/a.txt"))
    }

    func testAPathFallbackIdentifierResolvesAfterARename() {
        // ino 0 keeps the path in the id, so a rename changes the id: the map
        // records the new one and drops the old path.
        var map = FilesIdMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("a.txt", ino: 0)])
        XCTAssertEqual("path:a.txt", map.identifier(for: "a.txt"))
        map.invalidate(subtree: "a.txt")
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("b.txt", ino: 0)])
        XCTAssertEqual("path:b.txt", map.identifier(for: "b.txt"))
    }

    func testAPathKeepsItsIdentifierWhenTheInoChanges() {
        // A verified save renames a temp over the file: the inode is the temp's
        // now, but the item Finder knows must stay the same one.
        var map = FilesIdMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("a.txt", ino: 10)])
        let replaced = map.insert(fs: FsItem(name: "a.txt", dir: false, size: 9,
                                             mtime: 9, ino: 99, etag: "new"),
                                  path: "a.txt", parentIdentifier: FilesMap.rootIdentifier)
        XCTAssertEqual("ino:10", replaced.identifier)
        XCTAssertEqual("ino:10", map.identifier(for: "a.txt"))
        XCTAssertEqual("a.txt", map.path(for: "ino:10"))
    }

    func testAStalePathIsReResolvedFromTheParentListing() {
        // The map forgot the path (a delete); the next listing of the parent is
        // the one source that can give the item an identity again.
        var map = FilesIdMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("a.txt", ino: 10)])
        map.invalidate(subtree: "a.txt")
        XCTAssertNil(map.identifier(for: "a.txt"))
        let again = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                               items: [fs("a.txt", ino: 11)])
        XCTAssertEqual("ino:11", again.first?.identifier)
        XCTAssertEqual("ino:11", map.identifier(for: "a.txt"))
    }

    func testAPersistedPathThatHoldsAnotherFileGetsANewIdentifier() {
        var map = FilesIdMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("a.txt", ino: 6)])
        var reopened = FilesIdMap.decode(map.encoded())!
        XCTAssertEqual("ino:6", reopened.identifier(for: "a.txt"))
        // While the app was closed the phone's path came to hold another file.
        let second = reopened.insert(fs: fs("a.txt", ino: 7), path: "a.txt",
                                     parentIdentifier: FilesMap.rootIdentifier)
        XCTAssertEqual("ino:7", second.identifier)
        XCTAssertNil(reopened.path(for: "ino:6"))
    }

    func testAMapFromBeforeTheInodeWasRecordedIsCheckedToo() {
        // A map written before inodes were persisted has no "i": the first
        // listing is what says whether its path still holds that file.
        let legacy = Data("""
        {"version":2,"ids":{".rootContainer":{"p":"","n":".rootContainer"},"ino:6":{"p":"a.txt","n":".rootContainer"}}}
        """.utf8)
        var map = FilesIdMap.decode(legacy)!
        let listed = map.insert(fs: fs("a.txt", ino: 7), path: "a.txt",
                                parentIdentifier: FilesMap.rootIdentifier)
        XCTAssertEqual("ino:7", listed.identifier)
    }

    func testASavesIdentifierSurvivesARestart() {
        var map = FilesIdMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("a.txt", ino: 10)])
        // A verified save renames a temp over the file: the map records the
        // temp's ino with the identifier Finder already has.
        _ = map.insert(fs: fs("a.txt", ino: 99), path: "a.txt",
                       parentIdentifier: FilesMap.rootIdentifier, identifier: "ino:10")
        var reopened = FilesIdMap.decode(map.encoded())!
        let listed = reopened.insert(fs: fs("a.txt", ino: 99), path: "a.txt",
                                     parentIdentifier: FilesMap.rootIdentifier)
        XCTAssertEqual("ino:10", listed.identifier)
    }

    func testAPersistedMapRoundTrips() {
        var map = FilesIdMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("DCIM", dir: true, ino: 10), fs("a.txt", ino: 11)])
        _ = map.insert(childrenOf: "DCIM", parentIdentifier: "ino:10",
                       items: [fs("photo.jpg", ino: 12)])
        let decoded = FilesIdMap.decode(map.encoded())
        XCTAssertEqual(map, decoded)
        XCTAssertEqual("DCIM/photo.jpg", decoded?.path(for: "ino:12"))
        XCTAssertEqual("ino:10", decoded?.parent(for: "ino:12"))
    }

    func testACorruptOrForeignFileIsAFreshMap() {
        XCTAssertNil(FilesIdMap.decode(Data("not json".utf8)))
        XCTAssertNil(FilesIdMap.decode(Data("{}".utf8)))
        XCTAssertNil(FilesIdMap.decode(Data("{\"version\":1,\"ids\":{}}".utf8)))
        XCTAssertNil(FilesIdMap.decode(Data("{\"version\":2,\"ids\":{\"ino:1\":{}}}".utf8)))
        // A version from before S4 is not migrated: the domain is re-added.
        let fresh = FilesIdMap.load(URL(fileURLWithPath: "/tmp/pd-no-such-map-\(UUID().uuidString).json"))
        XCTAssertTrue(fresh.isEmpty)
        XCTAssertEqual("", fresh.path(for: FilesMap.rootIdentifier))
    }

    func testTheFileIsWrittenPrivateAndAtomically() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pd-map-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("files-ids.json")
        var map = FilesIdMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("a.txt", ino: 5)])
        FilesIdMap.save(map, to: url)
        XCTAssertEqual(map, FilesIdMap.load(url))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(0o600, (attributes[.posixPermissions] as? NSNumber)?.intValue)
        // The temp the write goes through is 0600 from the start and gone.
        XCTAssertEqual(["files-ids.json"], try FileManager.default.contentsOfDirectory(atPath: directory.path))
        // A second save replaces the file through the same temp: still one file.
        FilesIdMap.save(map, to: url)
        XCTAssertEqual(["files-ids.json"], try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(0o600, (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
        // A corrupt file on disk loads as a fresh map, never a crash.
        try Data("garbage".utf8).write(to: url)
        XCTAssertTrue(FilesIdMap.load(url).isEmpty)
    }
}

final class FilesConflictTests: XCTestCase {
    func testTheFirstConflictKeepsTheExtension() {
        XCTAssertEqual("a (from Mac).jpg", FilesConflict.name(for: "a.jpg"))
        XCTAssertEqual("report (from Mac).pdf", FilesConflict.name(for: "report.pdf"))
        XCTAssertEqual("archive.tar (from Mac).gz", FilesConflict.name(for: "archive.tar.gz"))
    }

    func testATakenNameIsNumbered() {
        var taken = Set(["a (from Mac).jpg"])
        XCTAssertEqual("a (from Mac 2).jpg",
                       FilesConflict.name(for: "a.jpg", taken: { taken.contains($0) }))
        taken.insert("a (from Mac 2).jpg")
        XCTAssertEqual("a (from Mac 3).jpg",
                       FilesConflict.name(for: "a.jpg", taken: { taken.contains($0) }))
    }

    func testNoExtensionAndDotFiles() {
        XCTAssertEqual("README (from Mac)", FilesConflict.name(for: "README"))
        XCTAssertEqual(".env (from Mac)", FilesConflict.name(for: ".env"))
        XCTAssertEqual(".gitignore (from Mac)", FilesConflict.name(for: ".gitignore"))
    }

    func testACollectedCreateGetsTheNextFreeName() {
        XCTAssertEqual("a 2.jpg", FilesConflict.collisionName(for: "a.jpg", attempt: 1))
        XCTAssertEqual("a 3.jpg", FilesConflict.collisionName(for: "a.jpg", attempt: 2))
        XCTAssertEqual("a 21.jpg", FilesConflict.collisionName(for: "a.jpg", attempt: 20))
        XCTAssertEqual("report 2.pdf", FilesConflict.collisionName(for: "report.pdf", attempt: 1))
        XCTAssertEqual("README 2", FilesConflict.collisionName(for: "README", attempt: 1))
        XCTAssertEqual("archive.tar 2.gz",
                       FilesConflict.collisionName(for: "archive.tar.gz", attempt: 1))
        XCTAssertNil(FilesConflict.collisionName(for: "a.jpg", attempt: 0))
        XCTAssertNil(FilesConflict.collisionName(for: "a.jpg", attempt: 21))
    }

    func testTheNumberedRetryStopsAtTwenty() {
        // Attempt 1 is the plain copy; 2…20 are numbered; there is no 21st.
        XCTAssertEqual("a (from Mac).jpg", FilesConflict.candidate(for: "a.jpg", attempt: 1))
        XCTAssertEqual("a (from Mac 2).jpg", FilesConflict.candidate(for: "a.jpg", attempt: 2))
        XCTAssertEqual("a (from Mac 20).jpg", FilesConflict.candidate(for: "a.jpg", attempt: 20))
        XCTAssertNil(FilesConflict.candidate(for: "a.jpg", attempt: 0))
        XCTAssertNil(FilesConflict.candidate(for: "a.jpg", attempt: 21))
        // A folder full of conflict copies: the retry gives up instead of
        // looping on the same taken name forever.
        let all = Set((1...20).compactMap { FilesConflict.candidate(for: "a.jpg", attempt: $0) })
        XCTAssertEqual(20, all.count)
        XCTAssertNil(FilesConflict.name(for: "a.jpg", taken: { all.contains($0) }))
        var almost = all
        almost.remove("a (from Mac 20).jpg")
        XCTAssertEqual("a (from Mac 20).jpg",
                       FilesConflict.name(for: "a.jpg", taken: { almost.contains($0) }))
    }
}

final class FilesErrorMapTests: XCTestCase {
    func testEveryCodeMaps() {
        let expected: [String: FilesFailure] = [
            "offline": .offline,
            "closed": .offline,
            "fs_not_found": .notFound,
            "fs_denied": .denied,
            "fs_stale": .stale,
            "fs_too_large": .tooLarge,
            "fs_exists": .exists,
            "fs_not_a_dir": .notADirectory,
            "fs_busy": .busy,
            "busy": .busy,
            "cancelled": .cancelled,
            "io": .io,
            "checksum": .io,
            "protocol": .protocolError,
            "something_else": .protocolError,
        ]
        for (code, failure) in expected {
            XCTAssertEqual(failure, FilesFailure.from(code: code), code)
        }
    }

    func testACreateCollisionAsksForAnotherName() {
        // `fs_exists` on a create means the system must retry under another
        // name; every other refusal is not a name collision.
        XCTAssertTrue(FilesFailure.from(code: "fs_exists").needsAnotherName)
        XCTAssertFalse(FilesFailure.from(code: "fs_denied").needsAnotherName)
        XCTAssertFalse(FilesFailure.from(code: "fs_stale").needsAnotherName)
        XCTAssertFalse(FilesFailure.offline.needsAnotherName)
    }
}

final class FilesModifyDecisionTests: XCTestCase {
    private let old = FilesModifyValues(name: "a.txt", parent: "ino:2", mtime: 1000)
    private let new = FilesModifyValues(name: "a.txt", parent: "ino:2", mtime: 1000)

    /// The 20 s bug's other half: after a preview the system sends a modify for
    /// its replica only (last-used date, tags, favourite rank). Nothing here
    /// reaches the phone.
    func testNothingStoredChangedIsNoWrite() {
        XCTAssertFalse(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(), old: old, new: new))
        XCTAssertFalse(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(), old: nil, new: new))
    }

    func testEachStoredFieldIsAWrite() {
        XCTAssertTrue(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(contents: true), old: old, new: new))
        XCTAssertTrue(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(filename: true), old: old,
            new: FilesModifyValues(name: "b.txt", parent: "ino:2", mtime: 1000)))
        XCTAssertTrue(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(parent: true), old: old,
            new: FilesModifyValues(name: "a.txt", parent: "ino:3", mtime: 1000)))
        XCTAssertTrue(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(modificationDate: true), old: old,
            new: FilesModifyValues(name: "a.txt", parent: "ino:2", mtime: 2000)))
    }

    /// A field the system flags but whose value is the old one (the system can
    /// send `.contentModificationDate` with the cached date) is not a change.
    func testAFlaggedFieldWithTheSameValueIsNoWrite() {
        XCTAssertFalse(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(filename: true, parent: true, modificationDate: true),
            old: old, new: new))
        // A missing date and a missing new date are the same nothing.
        let noDate = FilesModifyValues(name: "a.txt", parent: "ino:2", mtime: nil)
        XCTAssertFalse(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(modificationDate: true), old: noDate, new: noDate))
    }

    /// A fresh extension process has no old values: a field the system reports
    /// as changed is a change then.
    func testWithoutOldValuesAFlaggedFieldIsAWrite() {
        XCTAssertTrue(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(filename: true), old: nil, new: new))
        XCTAssertTrue(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(parent: true), old: nil, new: new))
        XCTAssertTrue(FilesModifyDecision.needsPhoneWrite(
            FilesModifyChange(modificationDate: true), old: nil, new: new))
    }
}
