import SwiftUI
import AVFoundation

@MainActor final class NightCamera: ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var message: String?
    @Published private(set) var running = false
    @Published private(set) var fieldOfView = 60.0
    @Published private(set) var aspect = 16.0/9
    private let queue = DispatchQueue(label:"ru.ploit.night.camera",qos:.userInitiated)
    private var token = UUID()

    func start() async {
        guard !running else { return }
        let request = UUID(); token = request
        let status = AVCaptureDevice.authorizationStatus(for:.video)
        let allowed: Bool
        if status == .authorized { allowed = true }
        else if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for:.video) }
        else { allowed = false }
        guard token == request, !Task.isCancelled else { return }
        guard allowed else { message = "Камера выключена. Разрешите доступ в настройках iOS; карта неба работает без камеры."; return }
        let session = session
        queue.async {
            do {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back) else {
                    throw CocoaError(.featureUnsupported)
                }
                if session.inputs.isEmpty {
                    let input = try AVCaptureDeviceInput(device:device)
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                    guard session.canAddInput(input) else { session.commitConfiguration(); throw CocoaError(.featureUnsupported) }
                    session.addInput(input); session.commitConfiguration()
                }
                session.startRunning()
                let fov = Double(device.activeFormat.videoFieldOfView)
                let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let ratio = Double(dimensions.width)/Double(max(1,dimensions.height))
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.token == request else { return }
                    self.running = session.isRunning; self.fieldOfView = fov; self.aspect = ratio
                    self.message = session.isRunning ? nil:"Камера недоступна. Переключитесь в свободный обзор."
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.token == request else { return }
                    self.message = "Не удалось открыть камеру. Свободный обзор остаётся доступен."
                }
            }
        }
    }
    func stop() {
        token = UUID(); running = false
        let session = session
        queue.async { session.stopRunning() }
    }
    func focalLength(size: CGSize) -> Double {
        max(Double(size.width)*aspect,Double(size.height))/(2*tan(fieldOfView * .pi/360))
    }
}

private final class NightPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}
struct NightCameraPreview: UIViewRepresentable {
    let camera: NightCamera
    func makeUIView(context: Context) -> UIView {
        let view = NightPreviewView()
        view.preview.session = camera.session; view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: ()) { (view as? NightPreviewView)?.preview.session = nil }
}
