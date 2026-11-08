import XCTest
@testable import CaptureKit
final class CaptureMetadataTests: XCTestCase {
    func testFourCCAndCodable() throws {
        XCTAssertEqual(CaptureMetadata.fourCC(0x62676734), "bgg4")
        XCTAssertFalse(CaptureMetadata.currentModelIdentifier.isEmpty)
        let m = CaptureMetadata(modelIdentifier: "iPhone14,3", systemVersion: "18.5", iso: 50, exposureSeconds: 0.001, lensPosition: 0.5,
                                rawFormat: "bgg4", fallback: false, heicFromSamePress: true)
        XCTAssertEqual(try JSONDecoder().decode(CaptureMetadata.self, from: JSONEncoder().encode(m)), m)
        // Older capture.json files (no rawKind) still decode.
        let old = #"{"modelIdentifier":"iPhone15,2","systemVersion":"26","fallback":false,"heicFromSamePress":true}"#
        XCTAssertNil(try JSONDecoder().decode(CaptureMetadata.self, from: Data(old.utf8)).rawKind)
    }

    /// Capture tier is decided from capabilities, never from model names.
    func testRawTierPolicy() {
        XCTAssertEqual(RawTierPolicy.choose(.bayer, proRAWSupported: true, bayerAvailable: true), .bayer, "Bayer stays the default")
        XCTAssertEqual(RawTierPolicy.choose(.proRAWWhenSupported, proRAWSupported: true, bayerAvailable: true), .proRAW)
        XCTAssertEqual(RawTierPolicy.choose(.proRAWWhenSupported, proRAWSupported: false, bayerAvailable: true), .bayer, "non-Pro falls back to Bayer")
        XCTAssertNil(RawTierPolicy.choose(.proRAWWhenSupported, proRAWSupported: false, bayerAvailable: false), "nothing: HEIC-only fallback")
    }
}
