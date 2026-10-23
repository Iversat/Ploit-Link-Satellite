import SwiftUI
import ARKit
import AVFoundation

@MainActor final class SkyScanController: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    @Published private(set) var survey = SkySurvey()
    @Published private(set) var direction: SkyDirection?
    @Published private(set) var running = false
    @Published private(set) var message = "Обведите камерой небо с места установки антенны."
    @Published private(set) var moved = false
    var headingReady = false
    let session = ARSession()
    let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    private var lastSample: TimeInterval = 0
    private var origin: SIMD3<Float>?
    private var startToken = UUID()
    private var isPreview = false

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = .main
    }
    func start() async {
        let token = UUID(); startToken = token
        guard ARWorldTrackingConfiguration.isSupported else { message = "Камера AR недоступна на этом устройстве."; return }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for:.video)
        default: allowed = false
        }
        guard startToken == token, !Task.isCancelled else { return }
        guard allowed else { message = "Разрешите камеру в настройках iPhone, чтобы проверить обзор."; return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravityAndHeading
        configuration.isLightEstimationEnabled = false
        if supportsDepth { configuration.frameSemantics.insert(.sceneDepth) }
        // A lower capture resolution limits energy use without affecting the angular map.
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.framesPerSecond == 30 }).min(by:{ $0.imageResolution.width < $1.imageResolution.width }) {
            configuration.videoFormat = format
        }
        survey = SkySurvey(); origin = nil; moved = false; direction = nil; lastSample = 0
        session.run(configuration, options:[.resetTracking, .removeExistingAnchors])
        running = true
    }
    func stop() {
        startToken = UUID(); session.pause(); running = false; direction = nil
    }
    func mark(_ state: SkyCellState) {
        guard running, !moved, let direction, headingReady || isPreview else { return }
        survey.mark(direction,state:state)
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running, frame.timestamp - lastSample >= 0.2 else { return }
        lastSample = frame.timestamp
        guard case .normal = frame.camera.trackingState else {
            direction = nil; message = "Медленно поверните телефон: камера уточняет положение."; return
        }
        guard headingReady else { direction = nil; message = "Нужен точный компас: отойдите от металла и разрешите геопозицию."; return }
        let transform = frame.camera.transform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        if origin == nil { origin = position }
        if let origin, simd_distance(origin,position) > 1.5 {
            moved = true; stop(); message = "Точка изменилась. Начните новое сканирование у антенны."; return
        }
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        direction = Self.skyDirection(forward)
        message = "\(Int(direction?.azimuth ?? 0))° азимут · \(Int(direction?.elevation ?? 0))° высота"
        guard let direction, direction.elevation >= 0 else { message = "Поднимите камеру выше горизонта."; return }
        var result = survey
        result.observe(direction)
        if let depth = frame.sceneDepth, let confidence = depth.confidenceMap {
            let map = depth.depthMap
            CVPixelBufferLockBaseAddress(map,.readOnly); CVPixelBufferLockBaseAddress(confidence,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(map,.readOnly); CVPixelBufferUnlockBaseAddress(confidence,.readOnly) }
            if let base = CVPixelBufferGetBaseAddress(map), let quality = CVPixelBufferGetBaseAddress(confidence) {
                let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
                let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
                let qualityStride = CVPixelBufferGetBytesPerRow(confidence)
                let values = base.assumingMemoryBound(to:Float32.self), confidenceValues = quality.assumingMemoryBound(to:UInt8.self)
                let intrinsics = frame.camera.intrinsics, resolution = frame.camera.imageResolution
                for row in 1...5 { for column in 1...5 {
                    let x = column * width / 6, y = row * height / 6
                    let px = Float(x) * Float(resolution.width) / Float(width)
                    let py = Float(y) * Float(resolution.height) / Float(height)
                    let ray = SIMD4<Float>((px-intrinsics.columns.2.x)/intrinsics.columns.0.x,
                                           -(py-intrinsics.columns.2.y)/intrinsics.columns.1.y, -1, 0)
                    let world = transform * ray
                    let sample = Self.skyDirection(SIMD3<Float>(world.x,world.y,world.z))
                    result.observe(sample,obstacleDistance:Double(values[y*stride+x]),
                                   highConfidence:confidenceValues[y*qualityStride+x] == UInt8(ARConfidenceLevel.high.rawValue))
                } }
            }
        }
        survey = result
    }
    private static func skyDirection(_ vector: SIMD3<Float>) -> SkyDirection {
        let unit = simd_normalize(vector)
        // AR gravityAndHeading: +X east, +Y up, -Z north.
        return .init(azimuth:(atan2(Double(unit.x),Double(-unit.z))*180 / .pi+360).truncatingRemainder(dividingBy:360),
                     elevation:asin(min(1,max(-1,Double(unit.y))))*180 / .pi)
    }
    func session(_ session: ARSession, didFailWithError error: Error) { stop(); message = "Сканирование остановлено. Попробуйте ещё раз при лучшем освещении." }
    func sessionWasInterrupted(_ session: ARSession) { stop(); message = "Сканирование прервано. Начните заново с той же точки." }
    #if DEBUG
    func preview() {
        isPreview = true; headingReady = true
        for index in survey.cells.indices {
            let direction = SkySurvey.direction(at:index)
            if direction.elevation > 25 { survey.mark(direction,state:.clear) }
            if direction.azimuth > 220 && direction.azimuth < 290 && direction.elevation < 55 { survey.mark(direction,state:.blocked) }
        }
        message = "Пример карты · камера не используется"
    }
    #endif
}

struct SkyScanCamera: UIViewRepresentable {
    let controller: SkyScanController
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame:.zero)
        view.session = controller.session
        view.preferredFramesPerSecond = 30
        view.automaticallyUpdatesLighting = false
        view.accessibilityIdentifier = "skyCamera"
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {}
    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) { view.session.pause() }
}
