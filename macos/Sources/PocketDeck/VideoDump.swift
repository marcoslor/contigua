// `--dump-video DIR`: every stream's H.264 (parameter sets, then access units, as
// Annex-B) is written to DIR/stream-N.h264 for the end-to-end checks, which
// decode it with ffmpeg to look at what the phone drew. DIR/stream-N.pts holds
// one line per access unit: its presentation time in microseconds.

import Foundation

final class VideoDump {
    private let directory: URL
    private let queue = DispatchQueue(label: "dev.pocketdeck.videodump")
    private var handles: [String: FileHandle] = [:]

    init(directory: String) {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func write(config: VideoConfig, stream: UInt32) {
        append(Data(config.parameterSets), to: "stream-\(stream).h264")
    }

    func write(frame: VideoFrameData, stream: UInt32) {
        append(Data(frame.annexB), to: "stream-\(stream).h264")
        append(Data("\(frame.ptsUs)\n".utf8), to: "stream-\(stream).pts")
    }

    private func append(_ data: Data, to name: String) {
        queue.async { [self] in
            if handles[name] == nil {
                let url = directory.appendingPathComponent(name)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handles[name] = try? FileHandle(forWritingTo: url)
            }
            try? handles[name]?.write(contentsOf: data)
        }
    }
}
