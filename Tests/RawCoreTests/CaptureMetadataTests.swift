import XCTest
@testable import CaptureKit
final class CaptureMetadataTests: XCTestCase {
    func testFourCCAndCodable() throws {
        XCTAssertEqual(CaptureMetadata.fourCC(0x62676734), "bgg4")
        XCTAssertFalse(CaptureMetadata.currentModelIdentifier.isEmpty)
        let m = CaptureMetadata(modelIdentifier: "iPhone14,3", systemVersion: "18.5", iso: 50, exposureSeconds: 0.001, lensPosition: 0.5,
                                rawFormat: "bgg4", fallback: false, heicFromSamePress: true)
        XCTAssertEqual(try JSONDecoder().decode(CaptureMetadata.self, from: JSONEncoder().encode(m)), m)
    }
}
