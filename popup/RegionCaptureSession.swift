import CoreMedia
import Foundation
import ScreenCaptureKit

final class RegionCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayRegion: DisplayRegion
    private let sampleQueue: DispatchQueue
    private let frameHandler: @Sendable (CMSampleBuffer) -> Void
    private let failureHandler: @Sendable (Error) -> Void
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var isStopping = false

    init(
        displayRegion: DisplayRegion,
        frameHandler: @escaping @Sendable (CMSampleBuffer) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) {
        self.displayRegion = displayRegion
        self.frameHandler = frameHandler
        self.failureHandler = failureHandler
        sampleQueue = DispatchQueue(label: "popup.capture.sample.\(UUID().uuidString)", qos: .userInteractive)
        super.init()
    }

    func start() async throws {
        stateLock.withLock {
            isStopping = false
        }

        let filter: SCContentFilter
        if let window = displayRegion.window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            filter = SCContentFilter(
                display: displayRegion.display,
                excludingApplications: [],
                exceptingWindows: []
            )
        }

        let configuration = SCStreamConfiguration()
        // sourceRect is only meaningful for display-region capture. Single-window
        // streams ignore it, so selected subregions are cropped locally in the panel.
        if displayRegion.window == nil {
            configuration.sourceRect = displayRegion.streamSourceRect
        }
        configuration.width = Int(displayRegion.streamOutputSize.width.rounded(.up))
        configuration.height = Int(displayRegion.streamOutputSize.height.rounded(.up))
        configuration.ignoreGlobalClipSingleWindow = displayRegion.window != nil
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 2
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.preservesAspectRatio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            let shouldStop = stateLock.withLock {
                if isStopping {
                    return true
                }
                self.stream = stream
                return false
            }
            if shouldStop {
                try? stream.removeStreamOutput(self, type: .screen)
                try? await stream.stopCapture()
            }
        } catch {
            try? stream.removeStreamOutput(self, type: .screen)
            try? await stream.stopCapture()
            throw CaptureSessionError(error)
        }
    }

    func stop() {
        let streamToStop = takeStreamForStopping()
        guard let streamToStop else { return }

        Task {
            try? streamToStop.removeStreamOutput(self, type: .screen)
            try? await streamToStop.stopCapture()
        }
    }

    // Awaitable variant used during app termination so the caller can wait for the
    // SCStream XPC round-trip to complete before allowing the process to exit.
    func stopAndWait() async {
        let streamToStop = takeStreamForStopping()
        guard let streamToStop else { return }

        try? streamToStop.removeStreamOutput(self, type: .screen)
        try? await streamToStop.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid, Self.frameIsComplete(sampleBuffer) else { return }
        frameHandler(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard !Self.isUserStoppedError(error) else { return }

        let shouldReportFailure = stateLock.withLock {
            guard !isStopping else { return false }
            self.isStopping = true
            self.stream = nil
            return true
        }

        if shouldReportFailure {
            self.failureHandler(CaptureSessionError(error))
        }
    }

    private func takeStreamForStopping() -> SCStream? {
        stateLock.withLock {
            guard !isStopping else { return nil }
            isStopping = true
            let streamToStop = stream
            stream = nil
            return streamToStop
        }
    }

    private static func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }

        return status == .complete
    }

    static func isUserStoppedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == SCStreamError.errorDomain,
              let code = SCStreamError.Code(rawValue: nsError.code) else {
            return false
        }

        return code == .userStopped
    }
}
