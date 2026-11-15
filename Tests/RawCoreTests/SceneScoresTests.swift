import XCTest
@testable import RawCore

/// 2026-11-15 architecture review: B (smooth scores) and C (ScenePrediction).
final class SceneScoresTests: XCTestCase {
    func ctx(p50: Double, iso: Double = 100, people: Double = 0, face: Double = 0, labels: [String: Double]? = nil) -> SceneContext {
        var c = SceneContext(logP1: -8, logP50: p50, logP99: 0, dynamicRangeStops: 6, clippedFraction: 0, iso: iso, faceCount: face > 0 ? 1 : 0, labels: labels)
        c.personFraction = people; c.largestFaceArea = face; return c
    }

    func testRamp() {
        XCTAssertEqual(ScenePrediction.ramp(0, from: 0, to: 1), 0)
        XCTAssertEqual(ScenePrediction.ramp(1, from: 0, to: 1), 1)
        XCTAssertEqual(ScenePrediction.ramp(0.5, from: 0, to: 1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ScenePrediction.ramp(-5.35, from: -4.6, to: -6.1), 0.5, accuracy: 1e-9, "decreasing ramp, midpoint -5.35")
        XCTAssertEqual(ScenePrediction.ramp(-5, from: -4.6, to: -6.1), 0.1754, accuracy: 1e-3, "smoothstep, not linear")
        XCTAssertEqual(ScenePrediction.ramp(3, from: 0, to: 1), 1)
    }

    /// The reason for B: neighbouring frames of one roll must not jump.
    func testNoCliffAroundTheOldDarkThreshold() {
        let a = DecisionEngine.lookIntensityOffset(context: ctx(p50: -5.34)).0
        let b = DecisionEngine.lookIntensityOffset(context: ctx(p50: -5.36)).0
        XCTAssertLessThan(abs(a - b), 0.005, "was 0.10 with the hard threshold")
        XCTAssertEqual(a, -0.05, accuracy: 0.01, "half way at the old threshold")
        var last: Float = 1
        for i in 0...40 {   // monotone: darker never gets more look
            let v = DecisionEngine.lookIntensityOffset(context: ctx(p50: -4 - Double(i) * 0.06)).0
            XCTAssertLessThanOrEqual(v, last + 1e-6); last = v
        }
    }

    func testTuningFilesKeepTheirValues() {
        // Ramp ends sit inside the tuning gap, so tuning files are unchanged (holdouts are reported, never tuned on).
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -4.57)).0, 0, "MTN01")
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -6.13)).0, -0.10, accuracy: 1e-6, "CAFE01")
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -2.27, iso: 125, people: 0.29)).0, -0.05, accuracy: 1e-6, "USR01 mooncake")
    }

    func testPeopleFromFaceOrMaskAndISO() {
        XCTAssertEqual(ctx(p50: -2, face: 0.02).prediction.people, 1)
        XCTAssertEqual(ctx(p50: -2, people: 0.03).prediction.people, 0.5, accuracy: 1e-9, "old threshold = midpoint")
        XCTAssertEqual(ctx(p50: -2, people: 0.01).prediction.people, 0)
        XCTAssertEqual(ctx(p50: -2, iso: 1600).prediction.highISO, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ctx(p50: -2, iso: 3200).prediction.highISO, 1)
        XCTAssertEqual(ctx(p50: -2, iso: 800).prediction.highISO, 0)
    }

    func testEnvironmentNeedsEvidenceAndMargin() {
        XCTAssertEqual(ctx(p50: -1, labels: ["outdoor": 0.98, "sky": 0.95]).prediction.environment, .outdoor)
        XCTAssertEqual(ctx(p50: -3, labels: ["sofa": 0.8, "structure": 0.6]).prediction.environment, .indoor)
        XCTAssertEqual(ctx(p50: -3, labels: ["outdoor": 0.6, "door": 0.55]).prediction.environment, .unknown, "too close to call")
        XCTAssertEqual(ctx(p50: -3, labels: ["mug": 0.9]).prediction.environment, .unknown, "no environment evidence")
        XCTAssertEqual(ctx(p50: -3, labels: nil).prediction.environment, .unknown)
        let s = ctx(p50: -1, labels: ["sky": 0.95]).prediction
        XCTAssertEqual(s.landscapeLabel, "sky"); XCTAssertEqual(s.landscape, 1)
        XCTAssertTrue(s.summary.hasPrefix("scene: outdoor"))
    }

    func testLandscapeFadesWithDarkness() {
        let day = DecisionEngine.lookIntensityOffset(context: ctx(p50: -1, labels: ["sky": 0.95])).0
        let dusk = DecisionEngine.lookIntensityOffset(context: ctx(p50: -5.35, labels: ["sky": 0.95])).0
        XCTAssertEqual(day, 0.05, accuracy: 1e-6)
        XCTAssertLessThan(dusk, 0, "at dusk darkness outweighs the landscape boost")
    }

    func testQualityGuardVerdict() {
        let b = QualityGuardPlugin.Measure(clipped: 0.01, medianY: 0.18)
        XCTAssertNil(QualityGuardPlugin.problem(QualityGuardPlugin.Measure(clipped: 0.014, medianY: 0.20), base: b))
        XCTAssertNotNil(QualityGuardPlugin.problem(QualityGuardPlugin.Measure(clipped: 0.03, medianY: 0.18), base: b), "clips +2 %")
        XCTAssertNotNil(QualityGuardPlugin.problem(QualityGuardPlugin.Measure(clipped: 0.01, medianY: 0.30), base: b), "+0.74 EV")
        XCTAssertNotNil(QualityGuardPlugin.problem(QualityGuardPlugin.Measure(clipped: 0.01, medianY: 0.11), base: b), "-0.71 EV")
    }

    func testQualityGuardIsRegisteredOffByDefaultAndLast() throws {
        let reg = PluginRegistry.standard
        XCTAssertEqual(reg.available.last?.id, "qualityGuard", "judges what the other plugins did")
        XCTAssertFalse(reg.defaultEnabled.contains("qualityGuard"), "0.3.0 output stays pixel-frozen until enabled on purpose")
        var st = RenderSettings.explicit; st.plugins = ["qualityGuard"]
        XCTAssertEqual(try reg.active(for: st).map(\.id), ["qualityGuard"])
        st.qualityGuardStrength = 0.4
        XCTAssertThrowsError(try st.validate())
    }
}
