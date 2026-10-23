import Foundation
import CoreGraphics
import simd

struct SkyScanTarget: Identifiable, Equatable {
    let id: Int
    let x: Double
    let y: Double
    let state: SkyCellState
    let collected: Bool
    let dwellFraction: Double
    var canCollect: Bool { (0.18...0.82).contains(x) && (0.18...0.82).contains(y) }
}

/// Camera rays use ARKit's gravityAndHeading frame: east +X, up +Y, north −Z.
/// The display transform includes the portrait rotation and camera-image crop.
struct SkyScanProjection {
    let cameraRotation: simd_float3x3
    let intrinsics: simd_float3x3
    let imageSize: CGSize
    let imageToViewport: CGAffineTransform

    static func worldDirection(_ direction: SkyDirection) -> SIMD3<Float>? {
        guard direction.azimuth.isFinite, direction.elevation.isFinite,
              (0...90).contains(direction.elevation) else { return nil }
        let az = direction.azimuth * .pi / 180, el = direction.elevation * .pi / 180
        return SIMD3(Float(sin(az) * cos(el)),Float(sin(el)),Float(-cos(az) * cos(el)))
    }
    func project(_ direction: SkyDirection) -> CGPoint? {
        guard let world = Self.worldDirection(direction), imageSize.width > 0, imageSize.height > 0 else { return nil }
        let local = cameraRotation.transpose * world
        let fx = intrinsics.columns.0.x, fy = intrinsics.columns.1.y
        guard local.x.isFinite, local.y.isFinite, local.z.isFinite, local.z < -0.0001,
              fx.isFinite, fy.isFinite, fx > 0, fy > 0 else { return nil }
        let pixel = CGPoint(x:Double(fx * local.x / -local.z + intrinsics.columns.2.x) / Double(imageSize.width),
                            y:Double(intrinsics.columns.2.y - fy * local.y / -local.z) / Double(imageSize.height))
        let point = pixel.applying(imageToViewport)
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return point
    }
}

struct SkyScanDwell {
    static let duration = 0.4
    private var entered: [Int:TimeInterval] = [:]
    private var previousTime: TimeInterval?

    mutating func reset() { entered = [:]; previousTime = nil }
    mutating func update(ids: Set<Int>, at timestamp: TimeInterval, enabled: Bool) -> [Int:Double] {
        guard enabled, timestamp.isFinite else { reset(); return [:] }
        if let previousTime, timestamp < previousTime || timestamp - previousTime > 0.25 { entered = [:] }
        previousTime = timestamp
        entered = entered.filter { ids.contains($0.key) }
        var progress: [Int:Double] = [:]
        for id in ids {
            let start = entered[id] ?? timestamp
            entered[id] = start
            progress[id] = min(1,max(0,(timestamp - start) / Self.duration))
        }
        return progress
    }
}
