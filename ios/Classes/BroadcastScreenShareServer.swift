import Foundation
import CoreMedia
import CoreVideo
import ReplayKit
import UIKit

/// Receives screen share frames from a ReplayKit Broadcast Extension via Unix domain socket.
/// The extension sends JPEG-encoded frames as HTTP responses; this server decodes them
/// back to CMSampleBuffers and delivers them via the `onSampleBuffer` callback.
class BroadcastScreenShareServer: NSObject {

    // MARK: - Public

    /// Called on each decoded video frame (on a background queue).
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Called when the broadcast extension starts / stops.
    var onBroadcastStarted: (() -> Void)?
    var onBroadcastStopped: (() -> Void)?

    private let appGroupIdentifier: String
    private let socketFileName = "rtc_SSFD"

    private var serverSocketHandle: Int32 = -1
    private var clientSocketHandle: Int32 = -1
    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    private var listenQueue: DispatchQueue?
    private var readQueue: DispatchQueue?
    private var isRunning = false

    private var darwinStartToken: Int32 = 0
    private var darwinStopToken: Int32 = 0
    private var observingDarwin = false

    private static let imageContext = CIContext(options: [.useSoftwareRenderer: false])

    // Reusable pixel buffer pool to avoid per-frame allocation
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    // MARK: - Init

    init(appGroupIdentifier: String) {
        self.appGroupIdentifier = appGroupIdentifier
        super.init()
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        observeDarwinNotifications()
        startSocketServer()
    }

    func stop() {
        isRunning = false
        removeDarwinObservers()
        closeClientConnection()
        closeServerSocket()
        pixelBufferPool = nil
    }

    // MARK: - Broadcast Picker

    /// Programmatically presents the system broadcast picker so the user can start
    /// the broadcast extension. `preferredExtension` is the bundle ID of the extension.
    func showBroadcastPicker(extensionBundleId: String) {
        DispatchQueue.main.async {
            let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
            picker.preferredExtension = extensionBundleId
            picker.showsMicrophoneButton = false

            // Simulate a tap on the picker's internal button to trigger the system UI.
            for subview in picker.subviews {
                if let button = subview as? UIButton {
                    button.sendActions(for: .touchUpInside)
                    break
                }
            }
        }
    }

    // MARK: - Darwin Notifications

    private func observeDarwinNotifications() {
        guard !observingDarwin else { return }
        observingDarwin = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()

        let startName = "iOS_BroadcastStarted" as CFString
        CFNotificationCenterAddObserver(
            center, Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let server = Unmanaged<BroadcastScreenShareServer>.fromOpaque(observer).takeUnretainedValue()
                server.onBroadcastStarted?()
            },
            startName, nil, .deliverImmediately
        )

        let stopName = "iOS_BroadcastStopped" as CFString
        CFNotificationCenterAddObserver(
            center, Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let server = Unmanaged<BroadcastScreenShareServer>.fromOpaque(observer).takeUnretainedValue()
                server.onBroadcastStopped?()
            },
            stopName, nil, .deliverImmediately
        )
    }

    private func removeDarwinObservers() {
        guard observingDarwin else { return }
        observingDarwin = false

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Socket Server

    private var socketFilePath: String? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        return container.appendingPathComponent(socketFileName).path
    }

    private func startSocketServer() {
        guard let path = socketFilePath else {
            print("IvsScreenShare: Failed to resolve app group container")
            return
        }

        // Remove stale socket file
        unlink(path)

        serverSocketHandle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocketHandle != -1 else {
            print("IvsScreenShare: Failed to create server socket")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            print("IvsScreenShare: Socket path too long")
            return
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { strncpy(ptr, $0, path.count) }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverSocketHandle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("IvsScreenShare: Bind failed (\(errno))")
            closeServerSocket()
            return
        }

        guard Darwin.listen(serverSocketHandle, 1) == 0 else {
            print("IvsScreenShare: Listen failed (\(errno))")
            closeServerSocket()
            return
        }

        print("IvsScreenShare: Server listening at \(path)")

        listenQueue = DispatchQueue(label: "ivs.screenshare.listen")
        listenQueue?.async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverSocketHandle, $0, &clientAddrLen)
                }
            }

            guard client != -1 else {
                if isRunning {
                    print("IvsScreenShare: Accept failed (\(errno))")
                }
                break
            }

            print("IvsScreenShare: Client connected")
            clientSocketHandle = client
            handleClientConnection(client)
        }
    }

    private func handleClientConnection(_ socketFd: Int32) {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketFd, &readStream, &writeStream)

        guard let input = readStream?.takeRetainedValue() as InputStream? else {
            Darwin.close(socketFd)
            return
        }

        inputStream = input
        outputStream = writeStream?.takeRetainedValue() as OutputStream?

        // Ensure socket closes when stream closes
        input.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        outputStream?.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))

        input.open()
        outputStream?.open()

        readQueue = DispatchQueue(label: "ivs.screenshare.read")
        readQueue?.async { [weak self] in
            self?.readFrames(from: input)
        }
    }

    // MARK: - Frame Reading

    private func readFrames(from stream: InputStream) {
        // Buffer for accumulating incoming data
        var accumulator = Data()
        let chunkSize = 65536
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while isRunning && stream.streamStatus != .closed && stream.streamStatus != .error {
            guard stream.hasBytesAvailable || stream.streamStatus == .open else {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }

            let bytesRead = stream.read(&buffer, maxLength: chunkSize)
            if bytesRead <= 0 {
                if bytesRead < 0 {
                    print("IvsScreenShare: Read error: \(String(describing: stream.streamError))")
                }
                break
            }

            accumulator.append(buffer, count: bytesRead)

            // Try to extract complete HTTP messages from the accumulator.
            // Use autoreleasepool to release CFHTTPMessage, CIImage, and other
            // Obj-C objects each iteration — without it they pile up on this
            // background queue and cause OOM.
            autoreleasepool {
                while let frame = extractHTTPMessage(from: &accumulator) {
                    processFrame(frame)
                }
            }
        }

        print("IvsScreenShare: Client disconnected")
        closeClientConnection()
    }

    /// Attempts to parse a complete CFHTTPMessage from the front of `data`.
    /// Returns the parsed frame on success and removes consumed bytes from `data`.
    private func extractHTTPMessage(from data: inout Data) -> ScreenShareFrame? {
        let message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false).takeRetainedValue()

        if !CFHTTPMessageAppendBytes(message, (data as NSData).bytes.bindMemory(to: UInt8.self, capacity: data.count), data.count) {
            return nil
        }

        guard CFHTTPMessageIsHeaderComplete(message) else {
            return nil
        }

        guard let contentLengthStr = CFHTTPMessageCopyHeaderFieldValue(message, "Content-Length" as CFString)?.takeRetainedValue() as String?,
              let contentLength = Int(contentLengthStr) else {
            return nil
        }

        // Check if we have the full body
        guard let body = CFHTTPMessageCopyBody(message)?.takeRetainedValue() as Data?,
              body.count >= contentLength else {
            return nil
        }

        let widthStr = CFHTTPMessageCopyHeaderFieldValue(message, "Buffer-Width" as CFString)?.takeRetainedValue() as String? ?? "0"
        let heightStr = CFHTTPMessageCopyHeaderFieldValue(message, "Buffer-Height" as CFString)?.takeRetainedValue() as String? ?? "0"
        let orientationStr = CFHTTPMessageCopyHeaderFieldValue(message, "Buffer-Orientation" as CFString)?.takeRetainedValue() as String? ?? "0"

        let width = Int(widthStr) ?? 0
        let height = Int(heightStr) ?? 0
        let orientation = UInt32(orientationStr) ?? 0

        // Calculate bytes consumed: serialize the complete message to determine its size
        guard let serialized = CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data? else {
            return nil
        }

        // Only consume if we have enough data
        guard data.count >= serialized.count else {
            return nil
        }

        let jpegData = body.prefix(contentLength)
        data.removeFirst(serialized.count)

        return ScreenShareFrame(
            jpegData: Data(jpegData),
            width: width,
            height: height,
            orientation: orientation
        )
    }

    // MARK: - Frame Processing

    private func processFrame(_ frame: ScreenShareFrame) {
        guard let sampleBuffer = createSampleBuffer(from: frame) else { return }
        onSampleBuffer?(sampleBuffer)
    }

    private func createSampleBuffer(from frame: ScreenShareFrame) -> CMSampleBuffer? {
        guard let pixelBuffer = jpegToPixelBuffer(frame.jpegData, width: frame.width, height: frame.height) else {
            return nil
        }

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let desc = formatDescription else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: CMTime.invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard createStatus == noErr else { return nil }
        return sampleBuffer
    }

    private func getOrCreatePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = pixelBufferPool, poolWidth == width, poolHeight == height {
            return pool
        }
        // Recreate pool for new dimensions
        pixelBufferPool = nil
        poolWidth = width
        poolHeight = height

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 2
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess else { return nil }
        pixelBufferPool = pool
        return pool
    }

    private func jpegToPixelBuffer(_ jpegData: Data, width: Int, height: Int) -> CVPixelBuffer? {
        guard let ciImage = CIImage(data: jpegData) else { return nil }

        let targetWidth = width > 0 ? width : Int(ciImage.extent.width)
        let targetHeight = height > 0 ? height : Int(ciImage.extent.height)

        guard let pool = getOrCreatePool(width: targetWidth, height: targetHeight) else {
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        BroadcastScreenShareServer.imageContext.render(ciImage, to: buffer)
        return buffer
    }

    // MARK: - Cleanup

    private func closeClientConnection() {
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
    }

    private func closeServerSocket() {
        if serverSocketHandle != -1 {
            Darwin.close(serverSocketHandle)
            serverSocketHandle = -1
        }
        // Remove the socket file
        if let path = socketFilePath {
            unlink(path)
        }
    }
}

// MARK: - Models

private struct ScreenShareFrame {
    let jpegData: Data
    let width: Int
    let height: Int
    let orientation: UInt32
}
