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
    /// "bayer" (single frame, roadmap default) or "proRAW" (Apple's multi-frame fused linear DNG, Pro models).
    public var rawKind: String? = nil

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

/// Which RAW to ask for. Decided from what the device can do, never from a list of model names.
public enum RawPreference: String, Codable, Sendable, CaseIterable {
    /// Bayer RAW, single frame (roadmap default; every supported iPhone).
    case bayer
    /// Apple ProRAW where the device supports it (multi-frame fusion: Smart HDR / Deep Fusion merged into a linear
    /// DNG; less noise and more highlight range in low light), Bayer elsewhere.
    case proRAWWhenSupported
}

public enum RawKind: String, Codable, Sendable { case bayer, proRAW }

/// Pure capture tier decision (testable without a camera).
public enum RawTierPolicy {
    public static func choose(_ preference: RawPreference, proRAWSupported: Bool, bayerAvailable: Bool) -> RawKind? {
        if preference == .proRAWWhenSupported, proRAWSupported { return .proRAW }
        return bayerAvailable ? .bayer : nil
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
import ImageIO

/// Roadmap step 1: one wide camera, Bayer RAW + HEIC in ONE capture request.
/// Not exercised in CI (no camera): it is compiled for iOS there; behaviour must be verified on a device.
public final class CaptureService: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?

    private struct Pending {
        var raw: Data?
        var heic: Data?
        var rawFormat: OSType?
        var rawKind: RawKind?
        var exif: [String: Any]?
        var errors: [String] = []
        var completion: (Result<CaptureResult, Error>) -> Void
    }
    private var pending: [Int64: Pending] = [:]
    private let lock = NSLock()

    public enum CaptureError: Error { case noCamera, cannotAddInput, cannotAddOutput, notRunning, nothingCaptured([String]) }

    public override init() { super.init() }

    /// Wide camera only (no virtual dual/triple device that switches lenses on its own).
    public func configure() throws {
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CaptureError.noCamera }
        lock.lock(); device = cam; lock.unlock()
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

    /// Bayer RAW format if the device offers one.
    public var bayerRawFormat: OSType? {
        output.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    }

    /// Current preference (default Bayer, the roadmap). Change it with `setRawPreference` on the session queue.
    public private(set) var rawPreference: RawPreference = .bayer
    public var proRAWSupported: Bool { output.isAppleProRAWSupported }

    /// Switch Bayer / ProRAW. Call on the session queue (after `configure`).
    public func setRawPreference(_ p: RawPreference) {
        session.beginConfiguration()
        output.isAppleProRAWEnabled = (p == .proRAWWhenSupported) && output.isAppleProRAWSupported
        session.commitConfiguration()
        rawPreference = p
    }

    /// The RAW format the next capture asks for, and what kind it is.
    public var selectedRaw: (format: OSType, kind: RawKind)? {
        let kind = RawTierPolicy.choose(rawPreference, proRAWSupported: output.isAppleProRAWEnabled, bayerAvailable: bayerRawFormat != nil)
        switch kind {
        case .proRAW:
            return output.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }.map { ($0, .proRAW) }
                ?? bayerRawFormat.map { ($0, .bayer) }
        case .bayer: return bayerRawFormat.map { ($0, .bayer) }
        case nil: return nil
        }
    }

    /// Call on the session queue after `session.startRunning()`.
    public func capture(completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        // capturePhoto without a running session / active connection raises an Objective-C exception: refuse instead.
        guard session.isRunning, output.connection(with: .video)?.isActive == true else { completion(.failure(CaptureError.notRunning)); return }
        let chosen = selectedRaw
        let raw = chosen?.format
        let settings: AVCapturePhotoSettings
        if let raw {
            settings = AVCapturePhotoSettings(rawPixelFormatType: raw, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        // AVFoundation raises NSInvalidArgumentException if photoQualityPrioritization is set on RAW settings
        // (found on device 2026-11-08). Only the HEIC-only fallback asks for .quality; with RAW the processed
        // HEIC uses the output's default prioritisation.
        if raw == nil { settings.photoQualityPrioritization = .quality }
        settings.flashMode = .off
        lock.lock(); pending[settings.uniqueID] = Pending(rawFormat: raw, rawKind: chosen?.kind, completion: completion); lock.unlock()
        output.capturePhoto(with: settings, delegate: self)
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        lock.lock(); defer { lock.unlock() }
        if let error {
            pending[id]?.errors.append("\(photo.isRawPhoto ? "RAW" : "HEIC"): \(error.localizedDescription)")
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            pending[id]?.errors.append("\(photo.isRawPhoto ? "RAW" : "HEIC"): no file data")
            return
        }
        if photo.isRawPhoto { pending[id]?.raw = data } else { pending[id]?.heic = data }
        // Exposure facts of THIS frame (not the device's live values).
        if pending[id]?.exif == nil { pending[id]?.exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] }
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock(); let entry = pending.removeValue(forKey: resolvedSettings.uniqueID); let cam = device; lock.unlock()
        guard let entry else { return }
        if let error { entry.completion(.failure(error)); return }
        guard entry.raw != nil || entry.heic != nil else { entry.completion(.failure(CaptureError.nothingCaptured(entry.errors))); return }
        // A RAW that was requested but failed is an error, not a silent "fallback".
        if entry.rawFormat != nil, entry.raw == nil { entry.completion(.failure(CaptureError.nothingCaptured(entry.errors))); return }
        let exif = entry.exif ?? [:]
        let meta = CaptureMetadata(
            modelIdentifier: CaptureMetadata.currentModelIdentifier,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.floatValue,
            exposureSeconds: (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
            lensPosition: cam?.lensPosition,
            rawFormat: entry.rawFormat.map { CaptureMetadata.fourCC($0) },
            fallback: entry.rawFormat == nil, heicFromSamePress: entry.raw != nil && entry.heic != nil, rawKind: entry.rawKind?.rawValue)
        entry.completion(.success(CaptureResult(dng: entry.raw, heic: entry.heic, metadata: meta)))
    }
}
#endif
