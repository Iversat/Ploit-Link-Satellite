import AVFoundation
import CoreMotion
import SwiftUI
import simd

struct ScanCameraFrame {
    let timestamp: TimeInterval
    let pixelBuffer: CVPixelBuffer
    let rotation: simd_float3x3
    let intrinsics: simd_float3x3
    let resolution: CGSize
    let displayTransform: CGAffineTransform
    let depthMap: CVPixelBuffer?
    let confidenceMap: CVPixelBuffer?
    let absoluteDepth: Bool
}

enum ScanCaptureGeometry {
    static func rawRotation(portrait basis: DeviceBasis) -> simd_float3x3 {
        func world(_ v: DirectionVector) -> SIMD3<Float> { .init(Float(-v.west),Float(v.up),Float(-v.north)) }
        // Raw landscape buffer rotated .right: image (x,y) -> portrait (1-y,x).
        return .init(world(basis.y.negative),world(basis.x),world(basis.z))
    }
    static func portraitTransform(image: CGSize,viewport: CGSize) -> CGAffineTransform {
        guard image.width > 0,image.height > 0,viewport.width > 0,viewport.height > 0 else { return .identity }
        let imageAspect = image.height/image.width, viewAspect = viewport.width/viewport.height
        let sx = max(1,imageAspect/viewAspect), sy = max(1,viewAspect/imageAspect)
        return .init(a:0,b:sy,c:-sx,d:0,tx:(1+sx)/2,ty:(1-sy)/2)
    }
}

/// Owns the active AVCaptureDevice, so LED commands cannot target an inactive
/// camera hidden behind ARKit. ARSession is paused before this session starts.
final class ScanCaptureCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label:"ru.ploit.scan.capture",qos:.userInitiated)
    private let motion = CMMotionManager()
    private var device: AVCaptureDevice?
    private var video: AVCaptureVideoDataOutput?
    private var depth: AVCaptureDepthDataOutput?
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var onFrame: ((ScanCameraFrame,Bool,Bool)->Void)?
    private var lastFrame = 0.0
    private var deliveryInFlight = false
    private var trueNorth = false
    private var viewport = CGSize(width:390,height:844)
    private var notification: NSObjectProtocol?
    var hardwareAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back)?.hasTorch == true
    }
    func setViewport(_ size: CGSize) { queue.async { self.viewport = size } }
    func start(onFrame: @escaping (ScanCameraFrame,Bool,Bool)->Void,
               failure: @escaping (String)->Void,
               completion: @escaping (Bool,Bool,String?)->Void) {
        queue.async {
            self.onFrame = onFrame; self.lastFrame = 0
            do {
                let preferred = AVCaptureDevice.default(.builtInLiDARDepthCamera,for:.video,position:.back)
                let wide = AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back)
                guard let camera = preferred?.hasTorch == true ? preferred:wide else { throw CocoaError(.featureUnsupported) }
                try self.configure(camera)
                self.device = camera
                self.trueNorth = CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical)
                self.motion.deviceMotionUpdateInterval = 1.0/60
                self.motion.startDeviceMotionUpdates(using:self.trueNorth ? .xTrueNorthZVertical:.xMagneticNorthZVertical)
                self.session.startRunning()
                if let old = self.notification { NotificationCenter.default.removeObserver(old) }
                self.notification = NotificationCenter.default.addObserver(forName:AVCaptureSession.runtimeErrorNotification,object:self.session,queue:nil) { _ in
                    DispatchQueue.main.async { failure("Камера остановлена системой. Завершите проверку и откройте её снова.") }
                }
                let result = self.applyTorch(true)
                let hasDepth = self.depth != nil
                DispatchQueue.main.async { completion(result.0,hasDepth,result.1) }
            } catch {
                self.motion.stopDeviceMotionUpdates(); self.session.stopRunning()
                DispatchQueue.main.async { completion(false,false,"Не удалось запустить камеру для фонарика. Завершите проверку и откройте её снова.") }
            }
        }
    }
    private func configure(_ camera: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        synchronizer = nil; depth = nil
        let input = try AVCaptureDeviceInput(device:camera)
        guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        if camera.deviceType == .builtInLiDARDepthCamera,
           let format = camera.formats.filter({
               let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
               return dimensions.width <= 1920 && !$0.supportedDepthDataFormats.isEmpty
                   && CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                   && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
           }).max(by:{ CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }),
           let depthFormat = format.supportedDepthDataFormats.filter({ CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32 }).last {
            session.sessionPreset = .inputPriority
            try camera.lockForConfiguration()
            camera.activeFormat = format; camera.activeDepthDataFormat = depthFormat
            camera.activeVideoMinFrameDuration = CMTime(value:1,timescale:30)
            camera.activeVideoMaxFrameDuration = CMTime(value:1,timescale:30)
            camera.unlockForConfiguration()
            let output = AVCaptureDepthDataOutput()
            if session.canAddOutput(output) { session.addOutput(output); output.isFilteringEnabled = true; depth = output }
        } else if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        guard session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
        session.addOutput(output); video = output
        if let connection = output.connection(with:.video) {
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
        }
        if let depth {
            if let connection = depth.connection(with:.depthData),connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            let sync = AVCaptureDataOutputSynchronizer(dataOutputs:[output,depth])
            sync.setDelegate(self,queue:queue); synchronizer = sync
        } else { output.setSampleBufferDelegate(self,queue:queue) }
    }
    func setTorch(_ enabled: Bool,completion: @escaping (Bool,String?)->Void) {
        queue.async {
            let result = self.applyTorch(enabled)
            DispatchQueue.main.async { completion(result.0,result.1) }
        }
    }
    private func applyTorch(_ enabled: Bool) -> (Bool,String?) {
        guard let device,device.hasTorch else { return (false,"На этой камере нет фонарика.") }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if enabled { try device.setTorchModeOn(level:0.7) } else { device.torchMode = .off }
        } catch { return (device.isTorchActive,"iOS не разрешила включить фонарик. Проверьте температуру iPhone и доступность фонарика в Пункте управления.") }
        for _ in 0..<10 {
            if device.isTorchActive == enabled { break }
            Thread.sleep(forTimeInterval:0.05)
        }
        return (device.isTorchActive,enabled && !device.isTorchActive ? "Светодиод не включился даже на активной камере. Проверьте фонарик в Пункте управления и температуру iPhone.":nil)
    }
    func shutdown() async {
        await withCheckedContinuation { continuation in stop { continuation.resume() } }
    }
    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.onFrame = nil
            _ = self.applyTorch(false)
            self.motion.stopDeviceMotionUpdates(); self.session.stopRunning()
            if let notification = self.notification { NotificationCenter.default.removeObserver(notification); self.notification = nil }
            if let completion { DispatchQueue.main.async(execute:completion) }
        }
    }
    func captureOutput(_ output: AVCaptureOutput,didOutput sampleBuffer: CMSampleBuffer,from connection: AVCaptureConnection) {
        consume(sampleBuffer,depth:nil)
    }
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let video,let value = collection.synchronizedData(for:video) as? AVCaptureSynchronizedSampleBufferData,!value.sampleBufferWasDropped else { return }
        let depthValue = depth.flatMap { collection.synchronizedData(for:$0) as? AVCaptureSynchronizedDepthData }
        consume(value.sampleBuffer,depth:depthValue?.depthDataWasDropped == false ? depthValue?.depthData:nil)
    }
    private func consume(_ sample: CMSampleBuffer,depth: AVDepthData?) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard !deliveryInFlight,viewport.width > 0,viewport.height > 0,time.isFinite,time-lastFrame >= 1.0/35,let pixel = CMSampleBufferGetImageBuffer(sample),let pose = motion.deviceMotion,
              abs(pose.timestamp-time) < 0.12,let callback = onFrame else { return }
        lastFrame = time
        let r = pose.attitude.rotationMatrix
        let basis = DeviceBasis(x:.init(north:r.m11,west:r.m12,up:r.m13),y:.init(north:r.m21,west:r.m22,up:r.m23),z:.init(north:r.m31,west:r.m32,up:r.m33))
        let size = CGSize(width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel))
        var intrinsics: simd_float3x3
        if let data = CMGetAttachment(sample,key:kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,attachmentModeOut:nil) as? Data,
           data.count >= MemoryLayout<simd_float3x3>.size {
            intrinsics = data.withUnsafeBytes { $0.loadUnaligned(as:simd_float3x3.self) }
        } else {
            let fov = Double(device?.activeFormat.videoFieldOfView ?? 60)*Double.pi/180
            let focal = Float(Double(size.width)/(2*tan(fov/2)))
            intrinsics = .init(.init(focal,0,0),.init(0,focal,0),.init(Float(size.width/2),Float(size.height/2),1))
        }
        let metres = depth?.converting(toDepthDataType:kCVPixelFormatType_DepthFloat32)
        let frame = ScanCameraFrame(timestamp:time,pixelBuffer:pixel,rotation:ScanCaptureGeometry.rawRotation(portrait:basis),
            intrinsics:intrinsics,resolution:size,displayTransform:ScanCaptureGeometry.portraitTransform(image:size,viewport:viewport),
            depthMap:metres?.depthDataMap,confidenceMap:nil,absoluteDepth:metres?.depthDataAccuracy == .absolute && metres?.depthDataQuality == .high)
        let active = device?.isTorchActive == true, referenced = trueNorth
        deliveryInFlight = true
        DispatchQueue.main.async {
            callback(frame,active,referenced)
            self.queue.async { self.deliveryInFlight = false }
        }
    }
}

private final class ScanCapturePreviewView: UIView {
    weak var capture: ScanCaptureCamera?
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        capture?.setViewport(bounds.size)
        if let connection = preview.connection,connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}
struct ScanCapturePreview: UIViewRepresentable {
    let capture: ScanCaptureCamera
    func makeUIView(context: Context) -> UIView {
        let view = ScanCapturePreviewView()
        view.capture = capture
        view.preview.session = capture.session; view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: UIView,context: Context) { capture.setViewport(view.bounds.size) }
    static func dismantleUIView(_ view: UIView,coordinator: ()) { (view as? ScanCapturePreviewView)?.preview.session = nil }
}
