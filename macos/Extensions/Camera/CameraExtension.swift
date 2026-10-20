// PocketDeck camera extension (spike, v0.2 #7).
//
// A minimal CoreMediaIO Camera Extension: one provider, one device, one
// 1280x720@30 source stream that sends a solid colour. It is the Apple
// "camera extension" template shape, cut down to what the spike needs, and it
// exists to answer one question in the VM: can an ad-hoc-signed system
// extension activate at all? It is built only for bundles made with
// `bundle.sh --with-camera`, which the host never uses.
//
// The real thing would replace SolidColorStreamSource with frames from the
// PocketDeck app (a socket carrying the phone's H.264, decoded here).

import CoreMedia
import CoreMediaIO
import CoreMediaIO.CMIOSampleBuffer
import CoreVideo
import Foundation

private let width: Int32 = 1280
private let height: Int32 = 720
private let frameRate: Int32 = 30

private final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    var device: CMIOExtensionDevice?
    weak var provider: CMIOExtensionProvider?

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { props.manufacturer = "PocketDeck" }
        if properties.contains(.providerName) { props.name = "PocketDeck Camera" }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}
}

private final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    var stream: CMIOExtensionStream?

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceModel] }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) { props.model = "PocketDeck Camera" }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

/// The stream source. While a client streams, a timer posts one BGRA frame per
/// tick: a solid colour, so nothing from the phone (or the Mac's camera) is
/// involved. The spike never reaches this code in the VM, but it is the shape
/// the product would fill with the phone's decoded frames.
private final class SolidColorStreamSource: NSObject, CMIOExtensionStreamSource {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.pocketdeck.camera.frames")
    private var sequence: UInt64 = 0
    private let formatDescription: CMFormatDescription
    private let pixelBuffer: CVPixelBuffer

    override init() {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMPixelFormat_32BGRA,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &description
        )
        formatDescription = description!

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(width),
            Int(height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        pixelBuffer = buffer!

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x40, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        super.init()
    }

    var formats: [CMIOExtensionStreamFormat] {
        let duration = CMTime(value: 1, timescale: frameRate)
        return [
            CMIOExtensionStreamFormat(
                formatDescription: formatDescription,
                maxFrameDuration: duration,
                minFrameDuration: duration,
                validFrameDurations: [duration]
            ),
        ]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            props.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: frameRate)
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(1000 / Int(frameRate)))
        source.setEventHandler { [weak self] in self?.sendFrame() }
        source.resume()
        timer = source
    }

    func stopStream() throws {
        timer?.cancel()
        timer = nil
    }

    private func sendFrame() {
        guard let stream = stream else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: frameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var unmanaged: Unmanaged<CMSampleBuffer>?
        let status = CMIOSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            formatDescription,
            &timing,
            sequence,
            0,
            &unmanaged
        )
        sequence += 1
        guard status == noErr, let sample = unmanaged?.takeRetainedValue() else { return }
        stream.send(
            sample,
            discontinuity: [],
            hostTimeInNanoseconds: CMClockGetTime(CMClockGetHostTimeClock()).nanoseconds
        )
    }

    weak var stream: CMIOExtensionStream?
}

@main
struct CameraExtensionMain {
    static func main() {
        let providerSource = ProviderSource()
        let provider = CMIOExtensionProvider(source: providerSource, clientQueue: nil)
        providerSource.provider = provider

        let deviceSource = DeviceSource()
        let streamSource = SolidColorStreamSource()
        let device = CMIOExtensionDevice(
            localizedName: "PocketDeck Camera",
            deviceID: UUID(),
            legacyDeviceID: "PocketDeckCamera",
            source: deviceSource
        )
        let stream = CMIOExtensionStream(
            localizedName: "PocketDeck Camera",
            streamID: UUID(),
            direction: .source,
            clockType: .hostTime,
            source: streamSource
        )
        streamSource.stream = stream
        deviceSource.stream = stream
        _ = runCatching { try device.addStream(stream) }
        _ = runCatching { try provider.addDevice(device) }

        CMIOExtensionProvider.startService(provider: provider)
        RunLoop.main.run()
    }
}

private func runCatching(_ body: () throws -> Void) -> Error? {
    do {
        try body()
        return nil
    } catch {
        NSLog("PocketDeck camera extension: %@", error.localizedDescription)
        return error
    }
}

private extension CMTime {
    /// Seconds as an integer number of nanoseconds, without overflowing.
    var nanoseconds: UInt64 {
        let seconds = Double(value) / Double(timescale)
        return UInt64(max(0, seconds * 1_000_000_000))
    }
}
