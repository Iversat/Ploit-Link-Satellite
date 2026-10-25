import SwiftUI
import ARKit
import AVFoundation
import UIKit

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

@MainActor protocol SkyScanTorchControlling: AnyObject {
    var available: Bool { get }
    var isOn: Bool { get }
    func setOn(_ enabled: Bool, completion: @escaping @MainActor (Bool,String?) -> Void)
}

@MainActor final class SkyScanController: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    @Published private(set) var survey = SkySurvey()
    @Published private(set) var direction: SkyDirection?
    @Published private(set) var running = false
    @Published private(set) var message = "Осмотрите камерой место установки антенны."
    @Published private(set) var moved = false
    @Published private(set) var isSnapshot = false
    @Published private(set) var collecting = false
    @Published private(set) var projectedTargets: [SkyScanTarget] = []
    @Published private(set) var coverageFraction = 0.0
    @Published private(set) var startAzimuth: Double?
    @Published private(set) var torchAvailable = false
    @Published private(set) var isTorchOn = false
    @Published private(set) var torchError: String?
    @Published var environment: SkyScanEnvironment = .automatic {
        didSet {
            sceneEnvironment = environmentEstimate.resolved(selection:environment)
            if sceneEnvironment != .outdoors { survey.restrictOpenSkyToApertures() }
        }
    }
    @Published private(set) var analysisStatus = "ИИ анализирует изображение на iPhone"
    @Published private(set) var analysedFrames = 0
    @Published private(set) var sceneEnvironment: SkyScanEnvironment = .automatic
    var coveredTargetCount: Int { survey.coveredCellCount }
    let totalTargetCount = SkySurvey.columns * SkySurvey.rows
    @Published var headingReady = false {
        didSet { if oldValue != headingReady { analysisEpoch = UUID(); dwell.reset() } }
    }
    var scanInstruction: String {
        if direction == nil { return "МЕДЛЕННО ПОВЕРНИТЕ ТЕЛЕФОН" }
        return sceneEnvironment == .indoors ? "ОСМОТРИТЕ СТЕНЫ, ОКНА И ПОТОЛОК":"СОБЕРИТЕ ТОЧКИ ВОКРУГ СЕБЯ"
    }
    var collectionViewport = CGRect.zero
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
    private let torch: SkyScanTorchControlling
    private var torchRequestID = UUID()
    private var torchChanging = false
    private var lastTorchRefresh: TimeInterval = 0
    private var feedback = SkyScanCollectionFeedback()
    private var collectionAnimation = SkyScanCollectionAnimation()
    private var collectionHaptic: UIImpactFeedbackGenerator?
    private let classifier = SkySceneClassifier.shared
    private var analysisTask: Task<Void,Never>?
    private var lastAnalysis: TimeInterval = 0
    private var environmentEstimate = SkySceneEnvironmentEstimate()
    private var analysisEpoch = UUID()

    init(torch: SkyScanTorchControlling? = nil) {
        self.torch = torch ?? SystemSkyScanTorch()
        super.init()
        session.delegate = self
        session.delegateQueue = .main
    }
    func start(observer: Observer?, collecting: Bool = true) async {
        let token = UUID(); startToken = token
        collectionViewport = .zero
        torchError = nil
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
            .filter({ $0.framesPerSecond == 30 && $0.captureDeviceType == .builtInWideAngleCamera })
            .min(by:{ $0.imageResolution.width < $1.imageResolution.width }) {
            configuration.videoFormat = format
        }
        isPreview = false
        if collecting {
            survey = SkySurvey(); coverageFraction = 0; origin = nil; moved = false
            scanObserver = observer; isSnapshot = false; startAzimuth = nil
            analysedFrames = 0; environmentEstimate = SkySceneEnvironmentEstimate()
            sceneEnvironment = environment; lastAnalysis = 0
            analysisStatus = "ИИ на устройстве · ожидаем кадр камеры"
        }
        feedback.reset(); collectionAnimation.reset()
        collectionHaptic = collecting ? UIImpactFeedbackGenerator(style:.soft):nil
        collectionHaptic?.prepare()
        direction = nil; lastTorchRefresh = 0; lastSample = 0; lastProjection = 0; projectedTargets = []; dwell.reset()
        self.collecting = collecting
        // Inspection resumes the same AR world, retaining the original antenna
        // position. It neither resets the map nor silently collects new coverage.
        session.run(configuration, options:collecting ? [.resetTracking,.removeExistingAnchors]:[])
        running = true
        requestTorch(false)
        message = collecting ? "Медленно осмотрите пространство вокруг: стены, окна и область над горизонтом."
            : "Осмотр сохранённой карты. Оставайтесь в исходной точке: после паузы камера уточняет привязку."
    }
    func stop() {
        startToken = UUID(); running = false; direction = nil; collecting = false
        analysisTask?.cancel(); analysisTask = nil
        analysisEpoch = UUID()
        collectionViewport = .zero
        requestTorch(false); session.pause()
        projectedTargets = []; dwell.reset(); feedback.reset(); collectionAnimation.reset(); collectionHaptic = nil
    }
    func finish() {
        stop(); isSnapshot = true
        message = "Сохранён снимок точки сканирования. После перемещения выполните проверку заново."
    }
    func invalidate(_ reason: String) {
        stop(); survey = SkySurvey(); coverageFraction = 0; startAzimuth = nil; isSnapshot = false; scanObserver = nil; origin = nil; message = reason
        analysedFrames = 0; environmentEstimate = SkySceneEnvironmentEstimate(); sceneEnvironment = .automatic
        analysisStatus = "Для анализа начните новое сканирование"
    }
    func checkLocation(_ observer: Observer?) {
        guard !isPreview else { return }
        guard running || isSnapshot, SkyScanLocation.changed(from:scanObserver,to:observer) else { return }
        invalidate("Координаты точки изменились или недоступны. Начните новое сканирование у антенны.")
    }
    func mark(_ state: SkyCellState) {
        guard running, collecting, !moved, let direction, headingReady || isPreview else { return }
        survey.mark(direction,state:state == .clear && sceneEnvironment != .outdoors ? .opening:state)
    }
    func toggleTorch() {
        guard running, !isPreview, !torchChanging, torch.available || torch.isOn else { return }
        torchError = nil
        requestTorch(!isTorchOn)
    }
    private func requestTorch(_ enabled: Bool) {
        let request = UUID(); torchRequestID = request; torchChanging = true
        torchAvailable = running && !isPreview && (torch.available || torch.isOn)
        torch.setOn(enabled) { [weak self] active,failure in
            guard let self, self.torchRequestID == request else { return }
            self.torchChanging = false
            self.isTorchOn = active
            self.torchAvailable = self.running && !self.isPreview && (self.torch.available || active)
            if let failure { self.torchError = failure; self.message = failure }
        }
    }
    private func refreshTorchState() {
        guard !torchChanging else { return }
        torchAvailable = running && !isPreview && (torch.available || torch.isOn)
        isTorchOn = torch.isOn
    }
    func setViewport(_ size: CGSize) {
        guard size != viewportSize else { return }
        viewportSize = size
        #if DEBUG
        if isPreview, direction != nil { projectedTargets = SkyScanPreviewGeometry.targets(survey:survey,size:size) }
        #endif
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running, frame.timestamp - lastProjection >= 1.0/35 else { return }
        lastProjection = frame.timestamp
        if frame.timestamp-lastTorchRefresh >= 0.2 {
            lastTorchRefresh = frame.timestamp; refreshTorchState()
        }
        guard case .normal = frame.camera.trackingState else {
            analysisEpoch = UUID()
            direction = nil; projectedTargets = []; dwell.reset()
            if analysedFrames == 0 { analysisStatus = "ИИ ожидает стабильный кадр камеры" }
            message = "Медленно поверните телефон: камера уточняет положение."; return
        }
        let transform = frame.camera.transform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        if origin == nil { origin = position }
        if let origin, simd_distance(origin,position) > 1.5 {
            moved = true; invalidate("Точка изменилась. Начните новое сканирование у антенны."); return
        }
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        direction = Self.skyDirection(forward)
        if startAzimuth == nil {
            startAzimuth = SkyScanInitialHeading.capture(current:nil,direction:direction,collecting:collecting,
                                                        trackingReady:true,headingReady:headingReady)
        }
        let sampleDue = frame.timestamp - lastSample >= 0.2
        if sampleDue {
            lastSample = frame.timestamp
            message = headingReady
                ? "\(collecting ? "Сбор точек" : "Осмотр снимка") · \(Int(direction?.azimuth ?? 0))° азимут · \(Int(direction?.elevation ?? 0))° высота"
                : "Точки видны, ИИ работает. Для записи направлений нужен компас: отойдите от металла и разрешите геопозицию."
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
                projection.project(world:SkyScanProjection.targetDirections[index]).map { (index,$0) }
            }
        }
        let candidates = Set(visible.compactMap { index,point -> Int? in
            guard !result.collectedCells.contains(index), SkyScanCollectionArea.contains(point,visible:collectionViewport) else { return nil }
            return index
        })
        let progress = dwell.update(ids:candidates,at:frame.timestamp,enabled:collecting && headingReady)
        let completed = Set(progress.filter { $0.value >= 1 }.map(\.key))
        let newlyCollected = collecting ? result.collect(completed):[]
        collectionAnimation.update(newIDs:newlyCollected,at:frame.timestamp,enabled:collecting && !isPreview)
        if feedback.shouldPulse(newCount:newlyCollected.count,at:frame.timestamp,collecting:collecting,preview:isPreview) {
            collectionHaptic?.impactOccurred(intensity:0.75)
            collectionHaptic?.prepare()
        }
        if collecting && !newlyCollected.isEmpty {
            survey = result
            if coverageFraction != result.coverageFraction { coverageFraction = result.coverageFraction }
        }
        analyse(frame:frame,rotation:cameraRotation)
        projectedTargets = visible.map { index,point in
            SkyScanTarget(id:index,x:Double(point.x),y:Double(point.y),state:result.cells[index],
                          collected:result.collectedCells.contains(index),dwellFraction:progress[index] ?? 0,
                          collectionProgress:collectionAnimation.progress(for:index,at:frame.timestamp))
        }
    }
    private func analyse(frame: ARFrame, rotation: simd_float3x3) {
        guard collecting, !isPreview, analysisTask == nil, frame.timestamp-lastAnalysis >= 0.65 else { return }
        lastAnalysis = frame.timestamp
        let token = startToken, epoch = analysisEpoch, timestamp = frame.timestamp
        let mappingReady = headingReady
        if analysedFrames == 0 { analysisStatus = "ИИ на устройстве · анализ первого кадра…" }
        let pixelBuffer = frame.capturedImage
        // These rays and depth samples belong to the SAME frame as the image.
        // Later phone rotations must never move an old inference to a new direction.
        let rays = Self.analysisRays(frame:frame,rotation:rotation)
        let classifier = self.classifier
        analysisTask = Task { [weak self] in
            defer { if let self, self.startToken == token { self.analysisTask = nil } }
            do {
                let classification = try await classifier.classify(pixelBuffer)
                guard !Task.isCancelled, let self, self.startToken == token, self.analysisEpoch == epoch,
                      self.running, self.collecting, !self.moved else { return }
                self.environmentEstimate.update(indoorEvidence:classification.indoorEvidence)
                self.sceneEnvironment = self.environmentEstimate.resolved(selection:self.environment)
                var updated = self.survey
                if self.sceneEnvironment != .outdoors { updated.restrictOpenSkyToApertures() }
                for ray in rays where mappingReady && self.headingReady {
                    let sample = classification.sample(rawX:ray.rawX,rawY:ray.rawY)
                    let state = SkySceneFusion.state(sample:sample,distance:ray.distance,depthReliable:ray.depthReliable,
                                                     environment:self.sceneEnvironment)
                    updated.applyAnalysis(index:ray.index,state:state,timestamp:timestamp)
                }
                self.survey = updated; self.analysedFrames += 1
                let mode: String
                switch self.sceneEnvironment {
                case .automatic: mode = "Уточняем обстановку"
                case .outdoors: mode = "Улица"
                case .indoors: mode = "Помещение · окна как возможные просветы"
                }
                self.analysisStatus = "ИИ · \(mode) · \(self.supportsDepth ? "камера + LiDAR":"камера")"
            } catch {
                guard !Task.isCancelled, let self, self.startToken == token, self.analysisEpoch == epoch, self.running else { return }
                // Depth still contributes when a model is unavailable. Never replace
                // failed ML with a colour heuristic claiming to recognize the sky.
                var updated = self.survey
                for ray in rays where ray.depthReliable && mappingReady && self.headingReady {
                    if let distance = ray.distance, distance.isFinite, (0.2...6).contains(distance) {
                        updated.applyAnalysis(index:ray.index,state:.blocked,timestamp:timestamp)
                    }
                }
                self.survey = updated
                self.analysisStatus = "ИИ недоступен · отметьте небо и препятствия вручную"
            }
        }
    }
    private static func analysisRays(frame: ARFrame, rotation: simd_float3x3) -> [SkyAnalysisRay] {
        let intrinsics = frame.camera.intrinsics, resolution = frame.camera.imageResolution
        let projection = SkyScanProjection(cameraRotation:rotation,intrinsics:intrinsics,imageSize:resolution,imageToViewport:.identity)
        let map = frame.sceneDepth?.depthMap, confidence = frame.sceneDepth?.confidenceMap
        if let map { CVPixelBufferLockBaseAddress(map,.readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence,.readOnly) }
        defer {
            if let map { CVPixelBufferUnlockBaseAddress(map,.readOnly) }
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence,.readOnly) }
        }
        return SkyScanProjection.targetDirections.enumerated().compactMap { index,world in
            guard let point = projection.project(world:world) else { return nil }
            var distance: Double?, reliable = false
            if let map, let confidence,
               let depthBase = CVPixelBufferGetBaseAddress(map), let qualityBase = CVPixelBufferGetBaseAddress(confidence) {
                let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
                let x = min(width-1,max(0,Int(point.x*CGFloat(width))))
                let y = min(height-1,max(0,Int(point.y*CGFloat(height))))
                let qualityX = min(CVPixelBufferGetWidth(confidence)-1,max(0,Int(point.x*CGFloat(CVPixelBufferGetWidth(confidence)))))
                let qualityY = min(CVPixelBufferGetHeight(confidence)-1,max(0,Int(point.y*CGFloat(CVPixelBufferGetHeight(confidence)))))
                let depth = depthBase.assumingMemoryBound(to:Float32.self)[y*CVPixelBufferGetBytesPerRow(map)/MemoryLayout<Float32>.stride+x]
                let local = rotation.transpose * world
                distance = Double(depth / max(0.0001,-local.z))
                reliable = qualityBase.assumingMemoryBound(to:UInt8.self)[qualityY*CVPixelBufferGetBytesPerRow(confidence)+qualityX] == UInt8(ARConfidenceLevel.high.rawValue)
            }
            return SkyAnalysisRay(index:index,rawX:Double(point.x),rawY:Double(point.y),distance:distance,depthReliable:reliable)
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
    func previewRoom(headingAvailable: Bool = true) {
        preview(capture:true)
        environment = .indoors
        headingReady = headingAvailable
        direction = .init(azimuth:135,elevation:-8)
        analysisStatus = "ИИ · помещение · пример карты"
    }
    func preview(capture: Bool = false, collecting: Bool = true) {
        stop()
        isPreview = true; headingReady = true
        if collecting || !survey.hasRecordedData {
            survey = SkySurvey.preview(); startAzimuth = 135
        }
        coverageFraction = survey.coverageFraction
        isSnapshot = true; self.collecting = capture && collecting
        if capture {
            direction = SkyScanPreviewGeometry.direction
            let size = viewportSize.width > 0 && viewportSize.height > 0 ? viewportSize:CGSize(width:390,height:844)
            projectedTargets = SkyScanPreviewGeometry.targets(survey:survey,size:size)
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
