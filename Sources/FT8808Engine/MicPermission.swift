import Foundation
@preconcurrency import AVFoundation

/// Microphone (audio input) TCC permission gate, shared by the live capture
/// sources. Throws `MicPermissionError.denied` if the user has refused.
enum MicPermission {
    static func request() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw MicPermissionError.denied
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw MicPermissionError.denied
        @unknown default:
            return
        }
    }
}

enum MicPermissionError: Error, CustomStringConvertible {
    case denied
    var description: String {
        "microphone permission denied — grant it in System Settings ▸ Privacy & Security ▸ Microphone"
    }
}
