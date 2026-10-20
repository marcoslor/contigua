// The pure half of S3 (FilesCore.swift): the bridge wire's incremental parser,
// the fs item → File Provider item mapping, the identifier ↔ path map and the
// error map. Nothing here touches FileProvider or a socket.

import Foundation
import XCTest
@testable import PocketDeck

final class FilesBridgeWireTests: XCTestCase {
    private func decode(_ data: Data) -> [BridgeEvent] {
        var decoder = BridgeDecoder()
        return decoder.feed([UInt8](data))
    }
    func testRequestsRoundTrip() {
        let requests: [BridgeRequest] = [
            .hello(id: 1, version: filesBridgeVersion),
            .list(id: 2, path: "DCIM", page: "1000"),
            .list(id: 3, path: "", page: nil),
            .stat(id: 4, path: "notes.txt"),
            .read(id: 5, path: "big.bin", offset: 10, length: 20, etag: "abcd"),
            .read(id: 6, path: "big.bin", offset: 0, length: 1, etag: nil),
            .cancel(id: 5),
        ]
        for request in requests {
            XCTAssertEqual([.request(request)], decode(BridgeWire.line(request)),
                           "\(request)")
        }
    }

    func testRepliesRoundTrip() {
        let replies: [BridgeReply] = [
            .hello(id: 1, version: 1, name: "Nicky", connected: true),
            .hello(id: 1, version: 1, name: nil, connected: false),
            .items(id: 2, page: "40", items: [
                FsItem(name: "a.txt", dir: false, size: 4, mtime: 5, ino: 6, etag: "aa"),
            ]),
            .items(id: 2, page: nil, items: []),
            .item(id: 3, item: FsItem(name: "DCIM", dir: true, size: 0, mtime: 1, ino: 9, etag: "bb")),
            .end(id: 4, size: 1024, sha256: "ff"),
            .error(id: 4, code: "fs_not_found"),
        ]
        for reply in replies {
            XCTAssertEqual([.reply(reply)], decode(BridgeWire.line(reply)), "\(reply)")
        }
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
        let stream = [UInt8](header) + [10, 20, 30, 40, 50, 60] + [UInt8](BridgeWire.line(.end(id: 5, size: 6, sha256: "x")))
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
        let stream = [UInt8](BridgeWire.line(.list(id: 9, path: "DCIM", page: nil)))
            + [UInt8](BridgeWire.dataHeader(id: 9, length: 2)) + [7, 8]
        var decoder = BridgeDecoder()
        var events: [BridgeEvent] = []
        for byte in stream {
            events += decoder.feed([byte])
        }
        XCTAssertEqual([
            .request(.list(id: 9, path: "DCIM", page: nil)),
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

    func testMalformedLinesBecomeInvalidWithoutTheirContents() {
        XCTAssertEqual([.invalid("bad_json")], decode(Data("not json\n".utf8)))
        XCTAssertEqual([.invalid("bad_id")], decode(Data("{\"t\":\"list\"}\n".utf8)))
        XCTAssertEqual([.invalid("bad_id")], decode(Data("{\"t\":\"cancel\",\"id\":0}\n".utf8)))
        XCTAssertEqual([.invalid("unknown_type")], decode(Data("{\"t\":\"wat\",\"id\":1}\n".utf8)))
        XCTAssertEqual([.invalid("bad_request")], decode(Data("{\"t\":\"list\",\"id\":1}\n".utf8)))
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
        XCTAssertEqual("ino:99:DCIM/photo.jpg", item.identifier)
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

    func testInoZeroFallsBackToThePath() {
        XCTAssertEqual("path:DCIM/notes.txt",
                       FilesMap.identifier(path: "DCIM/notes.txt", ino: 0))
        let item = FilesMap.item(path: "DCIM/notes.txt", parentIdentifier: "ino:1",
                                 fs: fs("notes.txt", ino: 0))
        XCTAssertEqual("path:DCIM/notes.txt", item.identifier)
        XCTAssertEqual("ino:12:x", FilesMap.identifier(path: "x", ino: 12))
        XCTAssertEqual(".rootContainer", FilesMap.identifier(path: "", ino: 0))
    }

    func testAnIdentifierCarriesItsPathSoAFreshInstanceCanResolveIt() {
        // The system runs the extension in several processes; a second one has
        // no map and must still resolve what the first one enumerated.
        let item = FilesMap.item(path: "DCIM/Camera/photo.jpg", parentIdentifier: "ino:7",
                                 fs: fs("photo.jpg", ino: 99))
        XCTAssertEqual("DCIM/Camera/photo.jpg", FilesMap.path(fromIdentifier: item.identifier))
        XCTAssertEqual("", FilesMap.path(fromIdentifier: FilesMap.rootIdentifier))
        XCTAssertEqual("a/b c.txt", FilesMap.path(fromIdentifier: "path:a/b c.txt"))
        XCTAssertNil(FilesMap.path(fromIdentifier: "ino:99"))
        XCTAssertNil(FilesMap.path(fromIdentifier: "something-else"))
    }
}

final class FilesPathMapTests: XCTestCase {
    private func fs(_ name: String, dir: Bool = false, ino: Int) -> FsItem {
        FsItem(name: name, dir: dir, size: 0, mtime: 1, ino: ino, etag: "e")
    }

    func testAListingFillsTheMapBothWays() {
        var map = FilesPathMap()
        let items = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                               items: [fs("DCIM", dir: true, ino: 10), fs("notes.txt", ino: 11)])
        XCTAssertEqual(["ino:10:DCIM", "ino:11:notes.txt"], items.map(\.identifier))
        XCTAssertEqual("DCIM", map.path(for: "ino:10:DCIM"))
        XCTAssertEqual("notes.txt", map.path(for: "ino:11:notes.txt"))
        XCTAssertEqual("ino:11:notes.txt", map.identifier(for: "notes.txt"))
        XCTAssertEqual("", map.path(for: FilesMap.rootIdentifier))
    }

    func testNestedPathsAndSubtreeInvalidation() {
        var map = FilesPathMap()
        map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                   items: [fs("DCIM", dir: true, ino: 10)])
        _ = map.insert(childrenOf: "DCIM", parentIdentifier: "ino:10:DCIM",
                       items: [fs("Camera", dir: true, ino: 20)])
        _ = map.insert(childrenOf: "DCIM/Camera", parentIdentifier: "ino:20:DCIM/Camera",
                       items: [fs("a.jpg", ino: 21), fs("b.jpg", ino: 22)])
        XCTAssertEqual("DCIM/Camera/a.jpg", map.path(for: "ino:21:DCIM/Camera/a.jpg"))
        map.invalidate(subtree: "DCIM")
        XCTAssertNil(map.path(for: "ino:10:DCIM"))
        XCTAssertNil(map.path(for: "ino:20:DCIM/Camera"))
        XCTAssertNil(map.path(for: "ino:21:DCIM/Camera/a.jpg"))
        XCTAssertNil(map.identifier(for: "DCIM/Camera/a.jpg"))
    }

    func testARenameKeepsTheIdentifier() {
        var map = FilesPathMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("old.txt", ino: 30)])
        map.rename(identifier: "ino:30:old.txt", to: "new.txt")
        XCTAssertEqual("new.txt", map.path(for: "ino:30:old.txt"))
        XCTAssertNil(map.identifier(for: "old.txt"))
        XCTAssertEqual("ino:30:old.txt", map.identifier(for: "new.txt"))
    }

    func testRenamingAFolderMovesItsChildren() {
        var map = FilesPathMap()
        _ = map.insert(childrenOf: "", parentIdentifier: FilesMap.rootIdentifier,
                       items: [fs("old", dir: true, ino: 40)])
        _ = map.insert(childrenOf: "old", parentIdentifier: "ino:40:old",
                       items: [fs("a.txt", ino: 41)])
        map.rename(identifier: "ino:40:old", to: "new")
        XCTAssertEqual("new/a.txt", map.path(for: "ino:41:old/a.txt"))
        XCTAssertEqual("ino:41:old/a.txt", map.identifier(for: "new/a.txt"))
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
}
