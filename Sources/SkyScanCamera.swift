import SwiftUI
import ARKit
import AVFoundation

enum SkyScanLocation {
    static func changed(from previous: Observer?, to current: Observer?) -> Bool {
        guard let previous, let current else { return (previous == nil) != (current == nil) }
        guard previous.latitude.isFinite, previous.longitude.isFinite, previous.altitudeM.isFinite,
              current.latitude.isFinite, current.longitude.isFinite, current.altitudeM.isFinite else { return true }
        let radians = Double.pi / 180
        let latitude = (current.latitude-previous.latitude)*radians
        let longitude = AimMath.wrap(current.longitude-previous.longitude)*radians
        let a = pow(sin(latitude/2),2) + cos(previous.latitude*radians)*cos(current.latitude*radians)*pow(sin(longitude/2),2)
        let distance = 6_371_000 * 2 * asin(sqrt(min(1,max(0,a))))
        // AR detects small moves while scanning; GPS only invalidates a stopped
        // snapshot after a significant change, rather than ordinary GPS noise.
        return distance > 25 || abs(current.altitudeM-previous.altitudeM) > 25
    }
}

@MainActor final class SkyScanController: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    @Published private(set) var survey = SkySurvey()
    @Published private(set) var direction: SkyDirection?
    @Published private(set) var running = false
    @Published private(set) var message = "Обведите камерой небо с места установки антенны."
    @Published private(set) var moved = false
    @Published private(set) var isSnapshot = false
    @Published private(set) var collecting = false
    @Published private(set) var projectedTargets: [SkyScanTarget] = []
    @Published private(set) var coverageFraction = 0.0
    var coveredTargetCount: Int { survey.coveredCellCount }
    let totalTargetCount = SkySurvey.columns * SkySurvey.rows
    var headingReady = false
    let session = ARSession()
    let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    private var lastSample: TimeInterval = 0
    private var lastProjection: TimeInterval = 0
    private var viewportSize = CGSize.zero
    private var dwell = SkyScanDwell()
    private var origin: SIMD3<Float>?
    private var scanObserver: Observer?
    private var startToken = UUID()
    private var isPreview = false

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = .main
    }
    func start(observer: Observer?, collecting: Bool = true) async {
        let token = UUID(); startToken = token
        if !collecting {
            guard survey.hasRecordedData else { message = "Сначала соберите карту обзора неба."; return }
            guard !SkyScanLocation.changed(from:scanObserver,to:observer) else {
                invalidate("Точка изменилась. Для нового места нужна новая карта."); return
            }
        }
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
        if supportsDepth && collecting { configuration.frameSemantics.insert(.sceneDepth) }
        // A lower capture resolution limits energy use without affecting the angular map.
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.framesPerSecond == 30 }).min(by:{ $0.imageResolution.width < $1.imageResolution.width }) {
            configuration.videoFormat = format
        }
        isPreview = false
        if collecting {
            survey = SkySurvey(); coverageFraction = 0; origin = nil; moved = false
            scanObserver = observer; isSnapshot = false
        }
        direction = nil; lastSample = 0; lastProjection = 0; projectedTargets = []; dwell.reset()
        self.collecting = collecting
        // Inspection resumes the same AR world, retaining the original antenna
        // position. It neither resets the map nor silently collects new coverage.
        session.run(configuration, options:collecting ? [.resetTracking,.removeExistingAnchors]:[])
        running = true
        message = collecting ? "Медленно обведите небо камерой: точки собираются после короткой остановки."
            : "Осмотр сохранённой карты. Оставайтесь в исходной точке: после паузы камера уточняет привязку."
    }
    func stop() {
        startToken = UUID(); session.pause(); running = false; direction = nil; collecting = false
        projectedTargets = []; dwell.reset()
    }
    func finish() {
        stop(); isSnapshot = true
        message = "Сохранён снимок точки сканирования. После перемещения выполните проверку заново."
    }
    func invalidate(_ reason: String) {
        stop(); survey = SkySurvey(); coverageFraction = 0; isSnapshot = false; scanObserver = nil; origin = nil; message = reason
    }
    func checkLocation(_ observer: Observer?) {
        guard !isPreview else { return }
        guard running || isSnapshot, SkyScanLocation.changed(from:scanObserver,to:observer) else { return }
        invalidate("Координаты точки изменились или недоступны. Начните новое сканирование у антенны.")
    }
    func mark(_ state: SkyCellState) {
        guard running, collecting, !moved, let direction, headingReady || isPreview else { return }
        survey.mark(direction,state:state)
    }
    func setViewport(_ size: CGSize) { viewportSize = size }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running, frame.timestamp - lastProjection >= 1.0/35 else { return }
        lastProjection = frame.timestamp
        guard case .normal = frame.camera.trackingState else {
            direction = nil; projectedTargets = []; dwell.reset()
            message = "Медленно поверните телефон: камера уточняет положение."; return
        }
        guard headingReady else {
            direction = nil; projectedTargets = []; dwell.reset()
            message = "Нужен точный компас: отойдите от металла и разрешите геопозицию."; return
        }
        let transform = frame.camera.transform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        if origin == nil { origin = position }
        if let origin, simd_distance(origin,position) > 1.5 {
            moved = true; invalidate("Точка изменилась. Начните новое сканирование у антенны."); return
        }
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        direction = Self.skyDirection(forward)
        let sampleDue = frame.timestamp - lastSample >= 0.2
        if sampleDue {
            lastSample = frame.timestamp
            message = "\(collecting ? "Сбор точек" : "Осмотр снимка") · \(Int(direction?.azimuth ?? 0))° азимут · \(Int(direction?.elevation ?? 0))° высота"
        }
        var result = survey
        let cameraRotation = simd_float3x3(SIMD3(transform.columns.0.x,transform.columns.0.y,transform.columns.0.z),
                                          SIMD3(transform.columns.1.x,transform.columns.1.y,transform.columns.1.z),
                                          SIMD3(transform.columns.2.x,transform.columns.2.y,transform.columns.2.z))
        var visible: [(Int,CGPoint)] = []
        if viewportSize.width > 0, viewportSize.height > 0 {
            let projection = SkyScanProjection(cameraRotation:cameraRotation,intrinsics:frame.camera.intrinsics,
                imageSize:frame.camera.imageResolution,
                imageToViewport:frame.displayTransform(for:.portrait,viewportSize:viewportSize))
            visible = result.cells.indices.compactMap { index in
                projection.project(SkySurvey.direction(at:index)).map { (index,$0) }
            }
        }
        let candidates = Set(visible.compactMap { index,point -> Int? in
            guard !result.collectedCells.contains(index), (0.18...0.82).contains(point.x), (0.18...0.82).contains(point.y) else { return nil }
            return index
        })
        let progress = dwell.update(ids:candidates,at:frame.timestamp,enabled:collecting)
        let newlyCollected = Set(progress.filter { $0.value >= 1 }.map(\.key))
        if collecting { result.collect(newlyCollected) }
        if let direction, direction.elevation < 0 {
            self.direction = nil
            if sampleDue { message = "Поднимите камеру выше горизонта." }
        }
        if collecting, sampleDue, let depth = frame.sceneDepth, let confidence = depth.confidenceMap {
            let map = depth.depthMap
            CVPixelBufferLockBaseAddress(map,.readOnly); CVPixelBufferLockBaseAddress(confidence,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(map,.readOnly); CVPixelBufferUnlockBaseAddress(confidence,.readOnly) }
            if let base = CVPixelBufferGetBaseAddress(map), let quality = CVPixelBufferGetBaseAddress(confidence) {
                let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
                let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
                let qualityStride = CVPixelBufferGetBytesPerRow(confidence)
                let values = base.assumingMemoryBound(to:Float32.self), confidenceValues = quality.assumingMemoryBound(to:UInt8.self)
                let intrinsics = frame.camera.intrinsics, resolution = frame.camera.imageResolution
                var blockedCellsThisFrame = Set<Int>()
                for row in 1...5 { for column in 1...5 {
                    let x = column * width / 6, y = row * height / 6
                    let px = Float(x) * Float(resolution.width) / Float(width)
                    let py = Float(y) * Float(resolution.height) / Float(height)
                    let ray = SIMD4<Float>((px-intrinsics.columns.2.x)/intrinsics.columns.0.x,
                                           -(py-intrinsics.columns.2.y)/intrinsics.columns.1.y, -1, 0)
                    let world = transform * ray
                    let sample = Self.skyDirection(SIMD3<Float>(world.x,world.y,world.z))
                    let distance = Double(values[y*stride+x] * simd_length(SIMD3<Float>(ray.x,ray.y,ray.z)))
                    var newConfidentSample = false
                    if confidenceValues[y*qualityStride+x] == UInt8(ARConfidenceLevel.high.rawValue), distance.isFinite, (0.2...6).contains(distance),
                       let cell = SkySurvey.index(azimuth:sample.azimuth,elevation:sample.elevation) {
                        newConfidentSample = blockedCellsThisFrame.insert(cell).inserted
                    }
                    result.observe(sample,obstacleDistance:distance,highConfidence:newConfidentSample)
                } }
            }
        }
        if collecting && (!newlyCollected.isEmpty || (sampleDue && frame.sceneDepth != nil)) {
            survey = result
            if coverageFraction != result.coverageFraction { coverageFraction = result.coverageFraction }
        }
        projectedTargets = visible.map { index,point in
            SkyScanTarget(id:index,x:Double(point.x),y:Double(point.y),state:result.cells[index],
                          collected:result.collectedCells.contains(index),dwellFraction:progress[index] ?? 0)
        }
    }
    private static func skyDirection(_ vector: SIMD3<Float>) -> SkyDirection {
        let unit = simd_normalize(vector)
        // AR gravityAndHeading: +X east, +Y up, -Z north.
        return .init(azimuth:(atan2(Double(unit.x),Double(-unit.z))*180 / .pi+360).truncatingRemainder(dividingBy:360),
                     elevation:asin(min(1,max(-1,Double(unit.y))))*180 / .pi)
    }
    func session(_ session: ARSession, didFailWithError error: Error) { invalidate("Сканирование остановлено. Попробуйте ещё раз при лучшем освещении.") }
    func sessionWasInterrupted(_ session: ARSession) { invalidate("Сканирование прервано. Начните заново с той же точки.") }
    #if DEBUG
    func preview(capture: Bool = false, collecting: Bool = true) {
        stop()
        isPreview = true; headingReady = true
        if collecting || !survey.hasRecordedData {
            survey = SkySurvey()
            for index in survey.cells.indices {
                let direction = SkySurvey.direction(at:index)
                if direction.elevation > 25 { survey.mark(direction,state:.clear) }
                if direction.azimuth > 220 && direction.azimuth < 290 && direction.elevation < 55 { survey.mark(direction,state:.blocked) }
            }
            survey.collect(Set(survey.cells.indices.filter { SkySurvey.direction(at:$0).azimuth < 180 }))
        }
        coverageFraction = survey.coverageFraction
        isSnapshot = true; self.collecting = capture && collecting
        if capture {
            direction = .init(azimuth:135,elevation:45)
            projectedTargets = (0..<20).map { index in
                let cell = 2*SkySurvey.columns+index
                return SkyScanTarget(id:cell,x:0.12+Double(index % 5)*0.19,y:0.15+Double(index / 5)*0.20,
                    state:survey.cells[cell],collected:survey.collectedCells.contains(cell),dwellFraction:index == 8 ? 0.65:0)
            }
        }
        message = "Демонстрация · камера не используется"
    }
    #endif
}

struct SkyScanCamera: UIViewRepresentable {
    let controller: SkyScanController
    func makeUIView(context: Context) -> ARSCNView {
        let view = SkyScanARView(frame:.zero)
        view.scanController = controller
        view.scene = SCNScene()
        view.session = controller.session
        view.preferredFramesPerSecond = 30
        view.automaticallyUpdatesLighting = false
        view.accessibilityIdentifier = "skyCamera"
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) { controller.setViewport(view.bounds.size) }
    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) { view.session.pause() }
}

private final class SkyScanARView: ARSCNView {
    weak var scanController: SkyScanController?
    override func layoutSubviews() {
        super.layoutSubviews()
        scanController?.setViewport(bounds.size)
    }
}
