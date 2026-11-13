import AppKit
import Foundation
import ScreenCaptureKit

struct CaptureSessionError: LocalizedError, Equatable {
    enum Kind: Equatable {
        case screenRecordingPermissionDenied
        case missingScreenCaptureEntitlement
        case userStopped
        case streamFailure(String)
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    init(_ error: Error) {
        if let captureError = error as? CaptureSessionError {
            self = captureError
            return
        }

        let nsError = error as NSError
        if nsError.domain == SCStreamError.errorDomain,
           let code = SCStreamError.Code(rawValue: nsError.code) {
            switch code {
            case .userDeclined:
                self.kind = .screenRecordingPermissionDenied
            case .missingEntitlements:
                self.kind = .missingScreenCaptureEntitlement
            case .userStopped:
                self.kind = .userStopped
            default:
                self.kind = .streamFailure(nsError.localizedDescription)
            }
        } else {
            self.kind = .streamFailure(error.localizedDescription)
        }
    }

    var opensScreenRecordingSettings: Bool {
        kind == .screenRecordingPermissionDenied
    }

    var errorDescription: String? {
        switch kind {
        case .screenRecordingPermissionDenied:
            "Screen Recording access is required before Popup can mirror a selected region. Grant access in Privacy & Security, then quit Popup completely and launch it again."
        case .missingScreenCaptureEntitlement:
            "Popup is missing the screen capture entitlement required by ScreenCaptureKit. Check the app signing settings and build configuration."
        case .userStopped:
            "Screen capture stopped."
        case .streamFailure(let message):
            message
        }
    }
}

enum ScreenRecordingSettings {
    static func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
