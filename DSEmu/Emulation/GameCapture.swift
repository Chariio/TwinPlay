// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Photos
import ReplayKit
import UIKit

/// Screenshots and gameplay video, saved to Photos (add-only access).
/// Video uses ReplayKit's in-app recording: the app's picture and game audio, no microphone.
@MainActor
enum GameCapture {
    enum Failure: LocalizedError {
        case noAccess, noImage, recorderUnavailable, failed(String)
        var errorDescription: String? {
            switch self {
            case .noAccess: return String(localized: "TwinPlay can't save to Photos. Allow it in Settings ▸ Privacy ▸ Photos.")
            case .noImage: return String(localized: "Nothing to capture yet.")
            case .recorderUnavailable: return String(localized: "Screen recording isn't available right now.")
            case .failed(let m): return m
            }
        }
    }

    private static func ensureAccess() async throws {
        let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard s == .authorized || s == .limited else { throw Failure.noAccess }
    }

    static func saveScreenshot(_ image: UIImage?) async throws {
        guard let image, let data = image.pngData() else { throw Failure.noImage }
        try await ensureAccess()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    static func startRecording() async throws {
        let r = RPScreenRecorder.shared()
        guard r.isAvailable else { throw Failure.recorderUnavailable }
        r.isMicrophoneEnabled = false
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            r.startRecording { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        }
    }

    static func stopRecording() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TwinPlay-\(UUID().uuidString).mp4")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            RPScreenRecorder.shared().stopRecording(withOutput: url) { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        try await ensureAccess()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }
}
