// Now Playing (docs/design/notify.md): the phone's chosen media session drives
// MPNowPlayingInfoCenter; the OS-side transport controls (Control Center's Now
// Playing, the menu bar's media widget) come back as `media.command`. A state
// with no media fields clears the platform's info. "Media part 2" adds the
// artwork, the position bar and seek, the choice among several playing apps and
// the phone's media volume.

import AppKit
import Foundation
import MediaPlayer

/// A `media.sessions` row: which phone app Now Playing can follow.
struct MediaSessionRow: Equatable, Identifiable {
    var key: String
    var pkg: String
    var app: String
    var playing: Bool

    var id: String { key }
}

/// The chosen session's artwork, as `media.art` delivered it. The Mac only ever
/// holds what the wire allows: JPEG, at most 512 px and 256 KiB.
struct MediaArtwork: Equatable {
    static let maxSide = 512
    static let maxBytes = 256 * 1024

    var mime: String
    var width: Int
    var height: Int
    var data: Data

    /// The wire values the Mac accepts, or nil (with a reason for the log).
    static func accepted(mime: String, width: Int, height: Int, data: Data) -> (MediaArtwork?, String?) {
        guard mime == "image/jpeg" else { return (nil, "mime") }
        guard width > 0, height > 0, width <= maxSide, height <= maxSide else { return (nil, "size") }
        guard !data.isEmpty, data.count <= maxBytes else { return (nil, "bytes") }
        guard NSImage(data: data) != nil else { return (nil, "decode") }
        return (MediaArtwork(mime: mime, width: width, height: height, data: data), nil)
    }

    /// A hash prefix for the log: never the picture itself.
    var hashPrefix: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(format: "%016lx", hash).prefix(8).description
    }
}

/// The phone's chosen session, as `media.state` delivered it.
struct MediaState: Equatable {
    static let empty = MediaState()

    var playing: Bool = false
    var pkg: String?
    var key: String?
    var title: String?
    var artist: String?
    var album: String?
    var durationMs: Int64?
    var positionMs: Int64?
    var rate: Double = 0
    /// The session's PlaybackState lists ACTION_SEEK_TO (part 2).
    var canSeek: Bool = false
    var volume: Int?
    var volumeMax: Int?
    /// Wall clock (seconds) when the Mac received the state, to advance position.
    var receivedAt: TimeInterval = 0

    /// The track title/artist/album triple — empty when the session has no media.
    var isEmptyInfo: Bool { (title ?? "").isEmpty && (artist ?? "").isEmpty && (album ?? "").isEmpty }

    /// The volume as a slider fraction, when the phone reports one.
    var volumeFraction: Double? {
        guard let volume, let volumeMax, volumeMax > 0 else { return nil }
        return Double(volume) / Double(volumeMax)
    }
}

/// A command the Mac sends (`media.command`), and its wire shape.
enum MediaCommand: Equatable {
    case transport(String)
    case seek(Int64)
    case volume(Int)

    var action: String {
        switch self {
        case .transport(let name): return name
        case .seek: return "seek"
        case .volume: return "volume"
        }
    }

    /// Recording line: numbers only, never text.
    var record: String {
        switch self {
        case .transport(let name): return "media command \(name)"
        case .seek(let ms): return "media command seek positionMs=\(ms)"
        case .volume(let level): return "media command volume level=\(level)"
        }
    }
}

/// The media messages as the wire carries them (unit-tested).
enum MediaMessage {
    static func command(_ command: MediaCommand, key: String? = nil) -> [String: Any] {
        var message: [String: Any] = ["t": "media.command", "action": command.action]
        switch command {
        case .transport: break
        case .seek(let ms): message["positionMs"] = Int(ms)
        case .volume(let level): message["level"] = level
        }
        if let key, !key.isEmpty { message["key"] = key }
        return message
    }

    static func choose(key: String) -> [String: Any] {
        ["t": "media.choose", "key": key]
    }
}

/// The menu bar media row's pure model (unit-tested): what it shows and which
/// rows the "Playing on phone" submenu lists.
enum MediaMenu {
    /// "Playing on phone: <app>" only while the phone reports several sessions.
    static func showsSessionPicker(_ rows: [MediaSessionRow]) -> Bool { rows.count >= 2 }

    static func chosenApp(_ rows: [MediaSessionRow], chosen: String?) -> String? {
        guard let chosen else { return rows.first?.app }
        return rows.first { $0.key == chosen }?.app ?? rows.first?.app
    }

    static func pickerTitle(_ rows: [MediaSessionRow], chosen: String?) -> String {
        "Playing on phone: \(chosenApp(rows, chosen: chosen) ?? "your phone")"
    }

    /// The row's second line: title and artist when the phone sent them.
    static func trackLine(_ s: MediaState) -> String? {
        let title = s.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = s.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty && artist.isEmpty { return nil }
        if artist.isEmpty { return title }
        if title.isEmpty { return artist }
        return "\(title) — \(artist)"
    }
}

/// Pure state → now-playing info (unit-tested). The platform advances the
/// elapsed time from the moment the info is set, with `rate` as the drift, so
/// the info carries the position as of receipt; `elapsed` is what a reader
/// (the recording line) would show now.
enum MediaMapping {
    static func nowPlayingInfo(_ s: MediaState, artwork: MediaArtwork? = nil) -> [String: Any]? {
        if s.isEmptyInfo && s.receivedAt == 0 { return nil }
        var info: [String: Any] = [:]
        if let title = s.title, !title.isEmpty { info[MPMediaItemPropertyTitle] = title }
        if let artist = s.artist, !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if let album = s.album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = s.durationMs, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000
        }
        if s.receivedAt > 0 { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position(of: s) }
        info[MPNowPlayingInfoPropertyPlaybackRate] = s.playing ? max(s.rate, 0.05) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let pkg = s.pkg, !pkg.isEmpty { info[MPNowPlayingInfoPropertyServiceIdentifier] = pkg }
        if let artwork, let image = NSImage(data: artwork.data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        return info
    }

    /// The position the phone reported, in seconds.
    static func position(of s: MediaState) -> Double {
        Double(s.positionMs ?? 0) / 1000
    }

    /// `positionMs` was measured at `receivedAt`; the elapsed value drifts with rate.
    static func elapsed(of s: MediaState, at now: TimeInterval? = nil) -> Double {
        let base = position(of: s)
        guard s.playing, s.rate > 0 else { return base }
        let drift = (now ?? Date().timeIntervalSince1970) - s.receivedAt
        return max(0, base + drift * min(s.rate, 8.0))
    }

    /// Where a 15 s skip lands: inside the track, also while paused.
    static func skipTarget(of s: MediaState, seconds: Double, at now: TimeInterval? = nil) -> Int64 {
        let base = elapsed(of: s, at: now) + seconds
        let duration = s.durationMs.map { Double($0) / 1000 }
        let clamped = max(0, min(base, duration ?? base))
        return Int64((clamped * 1000).rounded())
    }

    /// A position the command center asked for, clamped to the track.
    static func seekTarget(seconds: Double, durationMs: Int64?) -> Int64 {
        let ms = (seconds * 1000).rounded()
        let upper = durationMs.map { Double($0) } ?? Swift.max(ms, 0)
        return Int64(Swift.max(0, Swift.min(ms, upper)))
    }

    /// Recording lines: sizes and numbers, no text (privacy).
    static func record(set s: MediaState) -> String {
        "media set playing=\(s.playing) titleLen=\(s.title?.count ?? 0) artistLen=\(s.artist?.count ?? 0) "
            + "albumLen=\(s.album?.count ?? 0) durationMs=\(s.durationMs ?? -1) "
            + "elapsedMs=\(Int(elapsed(of: s) * 1000)) rate=\(String(format: "%.2f", s.rate)) "
            + "canSeek=\(s.canSeek ? 1 : 0) volume=\(s.volume ?? -1) volumeMax=\(s.volumeMax ?? -1) "
            + "key=\(s.key ?? "-")"
    }
}

/// Owns MPNowPlayingInfoCenter and the remote commands. `onCommand` goes to the
/// session (`media.command`). The `mediacmd` debug actions call the same
/// routing via `perform` / `choose`.
final class NowPlayingController {
    /// `--share-log`: record sets and commands (sizes and numbers only) instead.
    var log: URL?
    var onCommand: ((MediaCommand) -> Void)?
    var onChoose: ((String) -> Void)?
    /// The UI mirror: the menu bar extra reads the controller through it.
    var onChange: (() -> Void)?

    private(set) var current: MediaState?
    private(set) var sessions: [MediaSessionRow] = []
    private(set) var chosenKey: String?
    private(set) var artwork: MediaArtwork?

    private var registered = false

    func apply(_ s: MediaState) {
        current = s
        // A different session never inherits the previous one's picture; the
        // phone sends `media.art` when the new session has one.
        if s.key != artworkSessionKey { artwork = nil; artworkSessionKey = nil }
        if let key = s.key { chosenKey = key }
        let info = MediaMapping.nowPlayingInfo(s, artwork: artwork)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if log != nil {
            record(info == nil ? "media cleared" : MediaMapping.record(set: s))
        }
        registerCommands()
        updateCommandAvailability()
        onChange?()
    }

    /// `media.sessions`: the rows the submenu offers. The list is the phone's;
    /// the Mac only shows it.
    func applySessions(_ rows: [MediaSessionRow], chosen: String?) {
        sessions = rows
        if let chosen { chosenKey = chosen }
        registerCommands()
        updateCommandAvailability()
        record("media sessions n=\(rows.count) chosen=\(chosen ?? "-")")
        onChange?()
    }

    /// `media.art`: one picture per session key; no data clears it.
    func applyArt(key: String, mime: String?, width: Int?, height: Int?, data: Data?) {
        guard key == current?.key else {
            record("media art refused=key")
            return
        }
        guard let mime, let width, let height, let data else {
            artwork = nil
            artworkSessionKey = nil
            if let current { MPNowPlayingInfoCenter.default().nowPlayingInfo = MediaMapping.nowPlayingInfo(current) }
            record("media art cleared")
            onChange?()
            return
        }
        let (accepted, refusal) = MediaArtwork.accepted(mime: mime, width: width, height: height, data: data)
        guard let art = accepted else {
            record("media art refused=\(refusal ?? "bad")")
            return
        }
        artwork = art
        artworkSessionKey = key
        if let current { MPNowPlayingInfoCenter.default().nowPlayingInfo = MediaMapping.nowPlayingInfo(current, artwork: art) }
        record("media art w=\(art.width) h=\(art.height) bytes=\(art.data.count) hash=\(art.hashPrefix)")
        onChange?()
    }

    /// Nothing the phone plays at the moment: clear macOS Now Playing.
    func clear() {
        guard current != nil || !sessions.isEmpty || artwork != nil else { return }
        current = nil
        sessions = []
        chosenKey = nil
        artwork = nil
        artworkSessionKey = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateCommandAvailability()
        record("media cleared")
        onChange?()
    }

    /// The `mediacmd` debug action and what the MPRemoteCommand targets call.
    /// Seek and volume are bounded here as well, so the Mac never asks for a
    /// position outside the track or a level the session cannot reach.
    func perform(_ command: MediaCommand) {
        let bounded: MediaCommand
        switch command {
        case .seek(let ms):
            bounded = .seek(MediaMapping.seekTarget(seconds: Double(ms) / 1000, durationMs: current?.durationMs))
        case .volume(let level):
            if let max = current?.volumeMax, max > 0 {
                bounded = .volume(Swift.min(Swift.max(level, 0), max))
            } else {
                bounded = command
            }
        case .transport:
            bounded = command
        }
        record(bounded.record)
        onCommand?(bounded)
    }

    /// `media.choose`: the person picked another playing app.
    func choose(_ key: String) {
        record("media choose key=\(key)")
        onChoose?(key)
    }

    private var artworkSessionKey: String?

    private func updateCommandAvailability() {
        guard registered else { return }
        let center = MPRemoteCommandCenter.shared()
        let canSeek = current?.canSeek == true
        center.changePlaybackPositionCommand.isEnabled = canSeek
        center.skipForwardCommand.isEnabled = canSeek
        center.skipBackwardCommand.isEnabled = canSeek
        // 15 s steps: the phone seeks, the next media.state confirms.
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
    }

    private func registerCommands() {
        guard !registered else { return }
        registered = true
        let center = MPRemoteCommandCenter.shared()
        let pairs: [(MPRemoteCommand, String)] = [
            (center.playCommand, "play"),
            (center.pauseCommand, "pause"),
            (center.nextTrackCommand, "next"),
            (center.previousTrackCommand, "prev"),
        ]
        for (command, action) in pairs {
            command.addTarget { [weak self] _ in
                self?.perform(.transport(action))
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let current = self.current,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = MediaMapping.seekTarget(seconds: event.positionTime, durationMs: current.durationMs)
            self.perform(.seek(target))
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self, let current = self.current else { return .commandFailed }
            self.perform(.seek(MediaMapping.skipTarget(of: current, seconds: 15)))
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self, let current = self.current else { return .commandFailed }
            self.perform(.seek(MediaMapping.skipTarget(of: current, seconds: -15)))
            return .success
        }
    }

    private func record(_ line: String) {
        guard let log else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}
