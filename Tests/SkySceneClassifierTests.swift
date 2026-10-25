import XCTest
import CoreML
import CoreVideo
import UIKit
import CoreImage
@testable import PloitSatellite

final class SkySceneClassifierTests: XCTestCase {
    private func logits(width: Int = 1, height: Int = 1) throws -> MLMultiArray {
        let result = try MLMultiArray(shape:[1,150,NSNumber(value:height),NSNumber(value:width)],dataType:.float32)
        for index in 0..<result.count { result[index] = 0 }
        return result
    }

    func testRawCameraCoordinatesMapToClockwisePortraitMask() {
        let mask = SkySceneClassification(width:3,height:2,
            kinds:[.sky,.solid,.window,.unknown,.window,.sky],
            confidence:[0.91,0.92,0.93,0.94,0.95,0.96],indoorEvidence:nil)
        let cases: [(Double,Double,SkySceneKind,Float)] = [
            (0.25,0.8,.sky,0.91),(0.25,0.5,.solid,0.92),(0.25,0.2,.window,0.93),
            (0.75,0.8,.unknown,0.94),(0.75,0.5,.window,0.95),(0.75,0.2,.sky,0.96)
        ]
        for (x,y,kind,confidence) in cases {
            let sample = mask.sample(rawX:x,rawY:y)
            XCTAssertEqual(sample.kind,kind)
            XCTAssertEqual(sample.confidence,confidence,accuracy:0.00001)
        }
    }

    func testInvalidRawCoordinatesCannotBecomeConfidentSky() {
        let mask = SkySceneClassification(width:1,height:1,kinds:[.sky],confidence:[0.99],indoorEvidence:nil)
        for (x,y) in [(Double.nan,0.5),(0.5,Double.infinity),(-0.01,0.5),(0.5,1.01)] {
            let sample = mask.sample(rawX:x,rawY:y)
            XCTAssertEqual(sample.kind,.unknown)
            XCTAssertEqual(sample.confidence,0)
        }
    }

    func testDecoderUsesSoftmaxConfidenceAndRecognizesSkyHouseWindow() throws {
        let array = try logits(width:3)
        // ADE20K: sky=2, house=25 and windowpane=8, zero-based.
        array[2*3] = 12
        array[25*3+1] = 12
        array[8*3+2] = 12
        let mask = try SkySceneClassification.decode(array)
        XCTAssertEqual(mask.width,3); XCTAssertEqual(mask.height,1)
        XCTAssertEqual(mask.kinds,[.sky,.solid,.window])
        let expected = Float(1/(1+149*exp(-12.0)))
        for confidence in mask.confidence { XCTAssertEqual(confidence,expected,accuracy:0.0001) }
    }

    func testTiedClassesStayUnknownAndExtremeLogitsRemainFinite() throws {
        let uncertain = try SkySceneClassification.decode(logits())
        XCTAssertEqual(uncertain.kinds,[.unknown])
        XCTAssertLessThan(uncertain.confidence[0],0.01)
        let array = try logits()
        array[2] = 10_000
        let certain = try SkySceneClassification.decode(array)
        XCTAssertEqual(certain.kinds,[.sky])
        XCTAssertTrue(certain.confidence[0].isFinite)
        XCTAssertEqual(certain.confidence[0],1,accuracy:0.000001)
    }

    func testUnsupportedTensorShapeIsRejected() throws {
        let wrongClasses = try MLMultiArray(shape:[1,21,2,2],dataType:.float32)
        XCTAssertThrowsError(try SkySceneClassification.decode(wrongClasses))
        let missingSpatialAxes = try MLMultiArray(shape:[150],dataType:.float32)
        XCTAssertThrowsError(try SkySceneClassification.decode(missingSpatialAxes))
    }

    func testBundledModelRecognizesOutdoorHouseAndIndoorWindowPhotographs() async throws {
        let bundle = Bundle(for:Self.self)
        guard let houseURL = bundle.url(forResource:"house",withExtension:"jpg"),
              let roomURL = bundle.url(forResource:"room-comparison",withExtension:"png") else {
            throw XCTSkip("Diagnostic photographs are fetched by the site QA workflow.")
        }
        let house = try XCTUnwrap(UIImage(contentsOfFile:houseURL.path)?.cgImage)
        let comparison = try XCTUnwrap(UIImage(contentsOfFile:roomURL.path)?.cgImage)
        let room = try XCTUnwrap(comparison.cropping(to:CGRect(x:0,y:0,width:768,height:512)))
        let classifier = SkySceneClassifier()
        let outdoor = try await classifier.classify(rawCameraBuffer(from:house))
        let indoor = try await classifier.classify(rawCameraBuffer(from:room))
        func sample(_ mask: SkySceneClassification, _ x:Double, _ y:Double) -> SkySceneSample {
            mask.sample(rawX:y,rawY:1-x)
        }
        let sky = sample(outdoor,0.15,0.15)
        let facade = sample(outdoor,0.58,0.48)
        let wall = sample(indoor,0.25,0.19)
        let window = sample(indoor,0.06,0.39)
        XCTAssertEqual(sky.kind,.sky); XCTAssertGreaterThan(sky.confidence,0.85)
        XCTAssertEqual(facade.kind,.solid); XCTAssertGreaterThan(facade.confidence,0.72)
        XCTAssertEqual(wall.kind,.solid); XCTAssertGreaterThan(wall.confidence,0.72)
        XCTAssertEqual(window.kind,.window); XCTAssertGreaterThan(window.confidence,0.60)
        XCTAssertEqual(SkySceneFusion.state(sample:window,distance:nil,depthReliable:false,environment:.indoors),.opening)
        XCTAssertEqual(SkySceneFusion.state(sample:facade,distance:nil,depthReliable:false,environment:.outdoors),.blocked)
        XCTAssertGreaterThan(try XCTUnwrap(indoor.indoorEvidence),0.12)
    }

    private func rawCameraBuffer(from image:CGImage) throws -> CVPixelBuffer {
        // Counter-rotate the upright fixture, exactly undoing Vision's .right.
        let rotated = CIImage(cgImage:image).oriented(.left)
        let source = rotated.transformed(by:CGAffineTransform(translationX:-rotated.extent.minX,y:-rotated.extent.minY))
        let width = Int(source.extent.width), height = Int(source.extent.height)
        var buffer:CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer)
        XCTAssertEqual(status,kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CIContext(options:[.useSoftwareRenderer:true]).render(source,to:result,
            bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:CGColorSpaceCreateDeviceRGB())
        return result
    }
}
