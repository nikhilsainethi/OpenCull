import CoreGraphics
import Foundation
import XCTest
@testable import CullCore

final class AdaptiveStyleTests: XCTestCase {
    private func analysis(_ brightness: Float, faceArea: Float = 0.1) -> PhotoAnalysis {
        let side = CGFloat(sqrt(faceArea))
        return PhotoAnalysis(pixelWidth: 1000, pixelHeight: 1000, captureDate: nil,
                             sharpness: 300, subjectSharpness: 300, meanLuminance: brightness,
                             highlightClipping: max(0, brightness - 0.8), shadowClipping: max(0, 0.15 - brightness),
                             faces: [FaceInfo(boundingBox: CGRect(x: 0.1, y: 0.1, width: side, height: side), captureQuality: 0.7)],
                             aestheticScore: 0.3)
    }

    private func example(_ brightness: Float, faceArea: Float = 0.1) -> AdaptiveStyleExample {
        var recipe = EditRecipe()
        recipe.exposure = 1.6 - 2.4 * Double(brightness)
        recipe.temperature = 6300 + 900 * Double(faceArea)
        recipe.shadows = 0.3 * (1 - Double(brightness))
        recipe.saturation = 1.05 + 0.2 * Double(faceArea)
        return AdaptiveStyleExample(analysis: analysis(brightness, faceArea: faceArea), recipe: recipe)
    }

    private var examples: [AdaptiveStyleExample] {
        [Float(0.05), 0.15, 0.25, 0.4, 0.55, 0.65, 0.8, 0.9].enumerated().map {
            example($0.element, faceArea: $0.offset % 2 == 0 ? 0.08 : 0.25)
        }
    }

    func testLearnedExposureGeneralizesToHeldOutBrightnessBetterThanFixedRecipe() throws {
        let profile = try AdaptiveStyleProfile(examples: examples)
        XCTAssertEqual(profile.sampleCount, 8)
        let heldout = [Float(0.3), 0.7]
        let fixedMean = examples.map(\.recipe.exposure).reduce(0, +) / Double(examples.count)
        var adaptiveError = 0.0, fixedError = 0.0
        for brightness in heldout {
            let expected = example(brightness).recipe.exposure
            let actual = profile.recipe(for: analysis(brightness)).exposure
            adaptiveError += abs(actual - expected)
            fixedError += abs(fixedMean - expected)
        }
        XCTAssertLessThan(adaptiveError, fixedError * 0.6)
        XCTAssertLessThan(adaptiveError / Double(heldout.count), 0.22)
        XCTAssertGreaterThan(profile.recipe(for: analysis(0.2)).exposure, profile.recipe(for: analysis(0.8)).exposure + 0.8)
        print("Adaptive style held-out synthetic exposure MAE=\(adaptiveError/2), fixed-mean MAE=\(fixedError/2); not a photographic accuracy rate")
    }

    func testColorTargetsAlsoDependOnMeasuredSubjectContext() throws {
        let samples = (0..<12).map { i in example(Float(i % 6) * 0.12 + 0.12, faceArea: i < 6 ? 0.02 : 0.4) }
        let profile = try AdaptiveStyleProfile(examples: samples)
        let small = profile.recipe(for: analysis(0.4, faceArea: 0.03))
        let large = profile.recipe(for: analysis(0.4, faceArea: 0.38))
        XCTAssertGreaterThan(large.temperature, small.temperature + 150)
        XCTAssertGreaterThan(large.saturation, small.saturation + 0.02)
    }

    func testCompositionIsNeverLearnedOrPredicted() throws {
        let samples = examples.map { e -> AdaptiveStyleExample in
            var e = e; e.recipe.crop = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6); e.recipe.rotation = 90; return e
        }
        let result = try AdaptiveStyleProfile(examples: samples).recipe(for: analysis(0.4))
        XCTAssertNil(result.crop); XCTAssertEqual(result.rotation, 0)
        XCTAssertFalse(result.isIdentity)
    }

    func testSerializationKeepsPredictionsAndRejectsMalformedDimensions() throws {
        let profile = try AdaptiveStyleProfile(examples: examples)
        let data = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(AdaptiveStyleProfile.self, from: data)
        XCTAssertEqual(profile, restored)
        XCTAssertEqual(profile.recipe(for: analysis(0.6)), restored.recipe(for: analysis(0.6)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["coefficients"] = [[1.0, 2.0]]
        XCTAssertThrowsError(try JSONDecoder().decode(AdaptiveStyleProfile.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testInsufficientDegenerateOrInvalidExamplesAreRejected() throws {
        XCTAssertThrowsError(try AdaptiveStyleProfile(examples: Array(examples.prefix(5))))
        XCTAssertThrowsError(try AdaptiveStyleProfile(examples: Array(repeating: example(0.3), count: 8)))
        var invalid = examples; invalid[0].analysis.meanLuminance = .nan
        XCTAssertThrowsError(try AdaptiveStyleProfile(examples: invalid))
        invalid = examples; invalid[0].recipe.temperature = .infinity
        XCTAssertThrowsError(try AdaptiveStyleProfile(examples: invalid))
        invalid = examples; invalid[0].analysis.analysisWarnings = ["Vision failed"]
        XCTAssertThrowsError(try AdaptiveStyleProfile(examples: invalid))
    }

    func testOutOfDomainInputsAndImbalancedLightingRemainBounded() throws {
        let samples = [Float(0.03), 0.05, 0.06, 0.08, 0.11, 0.2, 0.23, 0.24].map { example($0) }
        let profile = try AdaptiveStyleProfile(examples: samples)
        let bright = profile.recipe(for: analysis(1, faceArea: 0.8))
        XCTAssertNoThrow(try bright.validated())
        XCTAssertLessThan(abs(bright.exposure), 2)
        var invalid = analysis(0.5); invalid.meanLuminance = .infinity
        XCTAssertNoThrow(try profile.recipe(for: invalid).validated())
        XCTAssertNil(bright.crop); XCTAssertEqual(bright.rotation, 0)
    }

    func testConstantPhotometricTargetsRoundTripWithoutFloatingPointRejection() throws {
        let constant = examples.map { source -> AdaptiveStyleExample in
            var source = source; source.recipe = EditRecipe(); source.recipe.exposure = 0.1; return source
        }
        let trained = try AdaptiveStyleProfile(examples: constant)
        let restored = try JSONDecoder().decode(AdaptiveStyleProfile.self, from: JSONEncoder().encode(trained))
        XCTAssertEqual(restored.recipe(for: analysis(0.2)).exposure, 0.1, accuracy: 1e-10)
        XCTAssertEqual(restored.recipe(for: analysis(0.8)).exposure, 0.1, accuracy: 1e-10)
    }

    func testCompositionOnlyExamplesCannotBePresentedAsLearnedEdits() throws {
        let geometry = examples.map { source -> AdaptiveStyleExample in
            var source = source; source.recipe = EditRecipe()
            source.recipe.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8); source.recipe.rotation = 12
            return source
        }
        XCTAssertThrowsError(try AdaptiveStyleProfile(examples: geometry))
    }

    func testMalformedFeatureScalesAreRejectedOnLoad() throws {
        let profile = try AdaptiveStyleProfile(examples: examples)
        let data = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["featureScales"] = Array(repeating: 0.0, count: 7)
        XCTAssertThrowsError(try JSONDecoder().decode(AdaptiveStyleProfile.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
