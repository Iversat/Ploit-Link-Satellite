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
    var collectionProgress: Double? = nil
    var canCollect: Bool { SkyScanCollectionArea.central.contains(CGPoint(x:x,y:y)) }
}

enum SkyScanCollectionArea {
    static let central = CGRect(x:0.18,y:0.18,width:0.64,height:0.64)
    static func contains(_ point: CGPoint, visible: CGRect) -> Bool {
        guard !visible.isInfinite, !visible.isNull,
              [visible.origin.x,visible.origin.y,visible.size.width,visible.size.height,point.x,point.y].allSatisfy(\.isFinite),
              visible.size.width > 0, visible.size.height > 0 else { return false }
        let area = central.intersection(visible)
        guard !area.isNull, area.width >= 0.05, area.height >= 0.05 else { return false }
        return area.contains(point)
    }
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
    static let targetDirections: [SIMD3<Float>] = (0..<SkySurvey.columns*SkySurvey.rows).map {
        worldDirection(SkySurvey.direction(at:$0))!
    }
    func project(_ direction: SkyDirection) -> CGPoint? {
        guard let world = Self.worldDirection(direction) else { return nil }
        return project(world:world)
    }
    func project(world: SIMD3<Float>) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
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

struct SkyScanCollectionAnimation {
    static let duration = 0.32
    private var collectedAt: [Int:TimeInterval] = [:]
    mutating func reset() { collectedAt = [:] }
    mutating func update(newIDs: Set<Int>, at time: TimeInterval, enabled: Bool) {
        guard enabled, time.isFinite else { reset(); return }
        collectedAt = collectedAt.filter { time >= $0.value && time-$0.value < Self.duration }
        for id in newIDs where collectedAt[id] == nil { collectedAt[id] = time }
    }
    func progress(for id: Int, at time: TimeInterval) -> Double? {
        guard let start = collectedAt[id], time.isFinite, time >= start, time-start < Self.duration else { return nil }
        return (time-start)/Self.duration
    }
    static func point(from origin: CGPoint, toward center: CGPoint, progress: Double) -> CGPoint {
        let t = CGFloat(min(1,max(0,progress.isFinite ? progress:0)))
        let eased = t*t*(3-2*t)
        return CGPoint(x:origin.x+(center.x-origin.x)*eased,y:origin.y+(center.y-origin.y)*eased)
    }
}

#if DEBUG
enum SkyScanPreviewGeometry {
    static let direction = SkyDirection(azimuth:175,elevation:45)
    static func projection(size: CGSize) -> SkyScanProjection {
        let azimuth = Float(direction.azimuth * .pi / 180)
        let forward = SkyScanProjection.worldDirection(direction)!
        let right = SIMD3<Float>(cos(azimuth),0,sin(azimuth))
        let up = simd_cross(right,forward)
        // A representative portrait pinhole camera. Real scans always use the
        // actual AR frame intrinsics and display transform, never these values.
        let focal = Float(size.height)/(2*tan(Float.pi*66/360))
        let intrinsics = simd_float3x3(SIMD3<Float>(focal,0,0),SIMD3<Float>(0,focal,0),
                                       SIMD3<Float>(Float(size.width/2),Float(size.height/2),1))
        return .init(cameraRotation:simd_float3x3(right,up,-forward),intrinsics:intrinsics,
                     imageSize:size,imageToViewport:.identity)
    }
    static func targets(survey: SkySurvey, size: CGSize) -> [SkyScanTarget] {
        guard size.width > 0, size.height > 0 else { return [] }
        let projection = projection(size:size)
        return survey.cells.indices.compactMap { index in
            guard let point = projection.project(world:SkyScanProjection.targetDirections[index]) else { return nil }
            return .init(id:index,x:Double(point.x),y:Double(point.y),state:survey.cells[index],
                         collected:survey.collectedCells.contains(index),dwellFraction:0)
        }
    }
}
#endif


struct SkyScanCollectionFeedback {
    static let minimumInterval = 0.25
    private var lastPulse: TimeInterval?
    mutating func reset() { lastPulse = nil }
    mutating func shouldPulse(newCount: Int, at time: TimeInterval, collecting: Bool, preview: Bool) -> Bool {
        guard collecting, !preview, newCount > 0, time.isFinite else { return false }
        if let lastPulse, time < lastPulse { self.lastPulse = nil }
        guard lastPulse == nil || time-lastPulse! >= Self.minimumInterval else { return false }
        lastPulse = time
        return true
    }
}

enum SkyScanInitialHeading {
    static func capture(current: Double?, direction: SkyDirection?, collecting: Bool,
                        trackingReady: Bool, headingReady: Bool) -> Double? {
        guard current == nil, collecting, trackingReady, headingReady, let direction,
              direction.azimuth.isFinite, direction.elevation.isFinite,
              (-89..<89).contains(direction.elevation) else { return current }
        // An almost vertical optical axis has no stable azimuth.
        return (direction.azimuth.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360)
    }
}
