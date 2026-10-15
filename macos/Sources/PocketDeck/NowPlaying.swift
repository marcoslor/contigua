// Now Playing (docs/design/notify.md): the phone's media session drives
// MPNowPlayingInfoCenter; the OS-side transport controls (Control Center's Now
// Playing, the menu bar's media widget) come back as `media.command`. A state
// with no media fields clears the platform's info.

import Foundation
import MediaPlayer

/// The phone's chosen session, as `media.state` delivered it.
struct MediaState: Equatable {
    static let empty = MediaState()

    var playing: Bool = false
    var pkg: String?
    var title: String?
    var artist: String?
    var album: String?
    var durationMs: Int64?
    var positionMs: Int64?
    var rate: Double = 0
    /// Wall clock (seconds) when the Mac received the state, to advance position.
    var receivedAt: TimeInterval = 0

    /// The track title/artist/album triple — empty when the session has no media.
    var isEmptyInfo: Bool { (title ?? "").isEmpty && (artist ?? "").isEmpty && (album ?? "").isEmpty }
}

/// Pure state → now-playing info (unit-tested). The platform advances the
/// elapsed time from the moment the info is set, with `rate` as the drift, so
/// the info carries the position as of receipt; `elapsed` is what a reader
/// (the recording line) would show now.
enum MediaMapping {
    static func nowPlayingInfo(_ s: MediaState) -> [String: Any]? {
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

    /// Recording lines: sizes and numbers, no text (privacy).
    static func record(set s: MediaState) -> String {
        "media set playing=\(s.playing) titleLen=\(s.title?.count ?? 0) artistLen=\(s.artist?.count ?? 0) "
            + "albumLen=\(s.album?.count ?? 0) durationMs=\(s.durationMs ?? -1) "
            + "elapsedMs=\(Int(elapsed(of: s) * 1000)) rate=\(String(format: "%.2f", s.rate))"
    }
}

/// Owns MPNowPlayingInfoCenter and the remote commands. `onCommand` goes to the
/// session (`media.command`). The `mediacmd` debug action calls the same
/// routing via `perform`.
final class NowPlayingController {
    /// `--share-log`: record sets and commands (sizes and numbers only) instead.
    var log: URL?
    var onCommand: ((String) -> Void)?

    private var registered = false
    private var current: MediaState?

    func apply(_ s: MediaState) {
        current = s
        let info = MediaMapping.nowPlayingInfo(s)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if log != nil {
            record(info == nil ? "media cleared" : MediaMapping.record(set: s))
        }
        registerCommands()
    }

    /// Nothing the phone plays at the moment: clear macOS Now Playing.
    func clear() {
        current = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if log != nil { record("media cleared") }
    }

    /// The `mediacmd` debug action and what the MPRemoteCommand targets call.
    func perform(_ action: String) {
        record("media command \(action)")
        onCommand?(action)
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
                self?.perform(action)
                return .success
            }
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
