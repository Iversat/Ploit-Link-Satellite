import Foundation
import CoreML
import Vision
import CoreVideo

enum SkySceneKind: UInt8, Sendable { case unknown, sky, solid, window }

struct SkySceneSample: Sendable, Equatable {
    let kind: SkySceneKind
    let confidence: Float
}

struct SkySceneClassification: Sendable {
    let width: Int
    let height: Int
    let kinds: [SkySceneKind]
    let confidence: [Float]
    let indoorEvidence: Float?

    /// The Vision mask is portrait-upright; ARKit pixels remain raw landscape.
    /// EXIF .right maps raw (x,y) to upright (1-y,x), without mirroring.
    func sample(rawX: Double, rawY: Double) -> SkySceneSample {
        guard width > 0, height > 0, rawX.isFinite, rawY.isFinite,
              (0...1).contains(rawX), (0...1).contains(rawY),
              kinds.count == width*height, confidence.count == kinds.count else {
            return .init(kind:.unknown,confidence:0)
        }
        let x = min(width-1,max(0,Int((1-rawY)*Double(width))))
        let y = min(height-1,max(0,Int(rawX*Double(height))))
        let index = y*width+x
        return .init(kind:kinds[index],confidence:confidence[index])
    }

    static func decode(_ logits: MLMultiArray) throws -> Self {
        let shape = logits.shape.map(\.intValue), strides = logits.strides.map(\.intValue)
        let offset: Int
        if shape.count == 4 && shape[0] == 1 { offset = 1 }
        else if shape.count == 3 { offset = 0 }
        else { throw SkySceneClassifierError.invalidOutput }
        guard shape[offset] == 150, shape[offset+1] > 0, shape[offset+2] > 0,
              shape[offset+1] <= 512, shape[offset+2] <= 512 else { throw SkySceneClassifierError.invalidOutput }
        let height = shape[offset+1], width = shape[offset+2]
        let channelStride = strides[offset], rowStride = strides[offset+1], columnStride = strides[offset+2]
        let floatPointer = logits.dataType == .float32 ? logits.dataPointer.assumingMemoryBound(to:Float.self):nil
        let doublePointer = logits.dataType == .double ? logits.dataPointer.assumingMemoryBound(to:Double.self):nil
        let halfPointer = logits.dataType == .float16 ? logits.dataPointer.assumingMemoryBound(to:Float16.self):nil
        guard floatPointer != nil || doublePointer != nil || halfPointer != nil else { throw SkySceneClassifierError.invalidOutput }
        func value(at address: Int) -> Float {
            if let floatPointer { return floatPointer[address] }
            if let halfPointer { return Float(halfPointer[address]) }
            return Float(doublePointer![address])
        }
        var kinds = [SkySceneKind](repeating:.unknown,count:width*height)
        var confidence = [Float](repeating:0,count:width*height)
        var evidence = Float(0), validPixels = 0
        // ADE20K indoor objects; buildings/trees/ground are deliberately absent.
        let indoorClasses: Set<Int> = [0,3,5,7,8,10,14,15,18,19,22,23,24,27,28,30,31,33,
                                       35,37,39,44,45,47,49,50,56,57,58,62,63,64,65,67,
                                       70,71,73,74,75,81,85,89,97,99,107,110,117,118,124,
                                       129,131,133,134,139,141,143,145,146]
        var scores = [Float](repeating:0,count:150)
        for y in 0..<height { for x in 0..<width {
            let base = y*rowStride+x*columnStride
            var best = -Float.infinity, label = 0, finite = true
            for channel in 0..<150 {
                let score = value(at:base+channel*channelStride)
                scores[channel] = score
                if !score.isFinite { finite = false; break }
                if score > best { best = score; label = channel }
            }
            guard finite else { continue }
            var sum = Float(0)
            for score in scores { sum += exp(score-best) }
            guard sum.isFinite, sum > 0 else { continue }
            let probability = 1/sum, index = y*width+x
            kinds[index] = probability <= 0.5 ? .unknown:label == 2 ? .sky:label == 8 ? .window:.solid
            confidence[index] = probability
            if probability >= 0.6 {
                validPixels += 1
                if indoorClasses.contains(label) { evidence += probability }
            }
        } }
        return .init(width:width,height:height,kinds:kinds,confidence:confidence,
                     indoorEvidence:validPixels >= max(1,width*height/4) ? evidence/Float(validPixels):nil)
    }
}

enum SkySceneClassifierError: Error {
    case missingModel, invalidOutput
}

/// Model and Vision request objects are confined to this serial queue. Camera
/// frames are retained only until their inference completes and are never saved.
final class SkySceneClassifier: @unchecked Sendable {
    private let queue = DispatchQueue(label:"ru.ploit.sky-scene.inference",qos:.utility)
    private var model: VNCoreMLModel?

    func classify(_ pixelBuffer: CVPixelBuffer) async throws -> SkySceneClassification {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let result = try autoreleasepool { () throws -> SkySceneClassification in
                        let request = VNCoreMLRequest(model:try loadModel())
                        request.imageCropAndScaleOption = .scaleFill
                        let handler = VNImageRequestHandler(cvPixelBuffer:pixelBuffer,orientation:.right,options:[:])
                        try handler.perform([request])
                        guard let values = request.results as? [VNCoreMLFeatureValueObservation],
                              let output = values.first(where:{ $0.featureName == "logits" })?.featureValue.multiArrayValue else {
                            throw SkySceneClassifierError.invalidOutput
                        }
                        return try SkySceneClassification.decode(output)
                    }
                    continuation.resume(returning:result)
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    private func loadModel() throws -> VNCoreMLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource:"SkyScene",withExtension:"mlmodelc")
                ?? Bundle(for:SkySceneClassifier.self).url(forResource:"SkyScene",withExtension:"mlmodelc") else {
            throw SkySceneClassifierError.missingModel
        }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .all
        #endif
        let loaded = try VNCoreMLModel(for:MLModel(contentsOf:url,configuration:configuration))
        model = loaded
        return loaded
    }
}
