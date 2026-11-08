import Foundation

/// What every capture stores next to the DNG (roadmap step 1). Pure Swift so it is testable anywhere.
public struct CaptureMetadata: Codable, Equatable, Sendable {
    /// utsname.machine, e.g. "iPhone14,3" (never the marketing name).
    public var modelIdentifier: String
    public var systemVersion: String
    public var iso: Float?
    public var exposureSeconds: Double?
    public var lensPosition: Float?
    /// FourCC of the RAW pixel format, e.g. "bgg4".
    public var rawFormat: String?
    /// true when the device returned no Bayer RAW and only the processed image was kept.
    public var fallback: Bool
    /// The HEIC was produced by the same shutter press (same AVCapturePhotoSettings), so it is a valid reference.
    public var heicFromSamePress: Bool

    public static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }

    public static var currentModelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

public struct CaptureResult: Sendable {
    /// Bayer RAW as DNG (nil in fallback).
    public var dng: Data?
    /// Processed HEIC from the same press (reference for "at least as good as Apple").
    public var heic: Data?
    public var metadata: CaptureMetadata
}

#if os(iOS)
import AVFoundation

/// Roadmap step 1: one wide camera, Bayer RAW + HEIC in ONE capture request.
/// Not exercised in CI (no camera): it is compiled for iOS there; behaviour must be verified on a device.
public final class CaptureService: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var pending: [Int64: (raw: Data?, heic: Data?, completion: (Result<CaptureResult, Error>) -> Void)] = [:]
    private let lock = NSLock()

    public enum CaptureError: Error { case noCamera, cannotAddInput, cannotAddOutput, nothingCaptured }

    public override init() { super.init() }

    /// Wide camera only (no virtual dual/triple device that switches lenses on its own).
    public func configure() throws {
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CaptureError.noCamera }
        device = cam
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: cam)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .quality
    }

    /// Bayer RAW format if the device offers one (ProRAW / linear formats are skipped on purpose).
    public var bayerRawFormat: OSType? {
        output.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    }

    public func capture(completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        let settings: AVCapturePhotoSettings
        if let raw = bayerRawFormat {
            settings = AVCapturePhotoSettings(rawPixelFormatType: raw, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        settings.photoQualityPrioritization = .speed   // fewer multi-frame fusions; RAW is single frame anyway
        settings.flashMode = .off
        lock.lock(); pending[settings.uniqueID] = (nil, nil, completion); lock.unlock()
        output.capturePhoto(with: settings, delegate: self)
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        lock.lock()
        if photo.isRawPhoto { pending[id]?.raw = data } else { pending[id]?.heic = data }
        lock.unlock()
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock(); let entry = pending.removeValue(forKey: resolvedSettings.uniqueID); lock.unlock()
        guard let entry else { return }
        if let error { entry.completion(.failure(error)); return }
        guard entry.raw != nil || entry.heic != nil else { entry.completion(.failure(CaptureError.nothingCaptured)); return }
        let meta = CaptureMetadata(
            modelIdentifier: CaptureMetadata.currentModelIdentifier,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            iso: device?.iso, exposureSeconds: device.map { CMTimeGetSeconds($0.exposureDuration) },
            lensPosition: device?.lensPosition,
            rawFormat: bayerRawFormat.map { CaptureMetadata.fourCC($0) },
            fallback: entry.raw == nil, heicFromSamePress: entry.raw != nil && entry.heic != nil)
        entry.completion(.success(CaptureResult(dng: entry.raw, heic: entry.heic, metadata: meta)))
    }
}
#endif
