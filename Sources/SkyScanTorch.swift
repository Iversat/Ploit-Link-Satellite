import ARKit
import AVFoundation

protocol ScanTorchDevice: AnyObject {
    var id: String { get }
    var supported: Bool { get }
    var available: Bool { get }
    var active: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

private final class CaptureScanTorchDevice: ScanTorchDevice {
    let device: AVCaptureDevice
    init(_ device: AVCaptureDevice) { self.device = device }
    var id: String { device.uniqueID }
    var supported: Bool { device.hasTorch && device.isTorchModeSupported(.on) }
    var available: Bool { device.isTorchAvailable }
    var active: Bool { device.isTorchActive }
    func setEnabled(_ enabled: Bool) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if enabled { try device.setTorchModeOn(level:AVCaptureDevice.maxAvailableTorchLevel); device.torchMode = .on }
        else if device.isTorchModeSupported(.off) { device.torchMode = .off }
    }
}

@MainActor final class SystemSkyScanTorch: SkyScanTorchControlling {
    private let resolve: () -> [ScanTorchDevice]
    private let queue = DispatchQueue(label:"ru.ploit.sky-scan.torch",qos:.userInitiated)
    private var used: [String:ScanTorchDevice] = [:]

    init(resolve: (() -> [ScanTorchDevice])? = nil) {
        self.resolve = resolve ?? {
            // Resolve AFTER ARSession has selected its capture device. The
            // physical wide camera is a fallback, never a second capture session.
            let cameras = [ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
                           AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back),
                           AVCaptureDevice.default(.builtInTripleCamera,for:.video,position:.back),
                           AVCaptureDevice.default(.builtInDualWideCamera,for:.video,position:.back)]
            var ids = Set<String>()
            return cameras.compactMap { camera in
                guard let camera, ids.insert(camera.uniqueID).inserted else { return nil }
                return CaptureScanTorchDevice(camera)
            }
        }
    }

    // A transient runtime-unavailable flag must not permanently disable the
    // button. The command resolves the active camera again and reports failure.
    var available: Bool { resolve().contains { $0.supported } }
    var isOn: Bool { used.values.contains { $0.active } }

    func setOn(_ enabled: Bool, completion: @escaping @MainActor (Bool,String?) -> Void) {
        let candidates = resolve().filter { $0.supported }
        for device in candidates { used[device.id] = device }
        let allUsed = Array(used.values)
        queue.async {
            var failure: String?
            if enabled {
                var requested = false
                for device in candidates where device.available {
                    do {
                        try device.setEnabled(true)
                        // A successful setter can leave the LED dark on an
                        // inactive camera. Wait off-main for hardware confirmation.
                        for _ in 0..<5 {
                            if device.active { break }
                            Thread.sleep(forTimeInterval:0.06)
                        }
                        if device.active { requested = true; break }
                        try? device.setEnabled(false)
                    }
                    catch { continue }
                }
                if !requested {
                    failure = candidates.isEmpty ? "На этом устройстве нет доступного фонарика."
                        : "Светодиод не включился. Камера или iOS ограничивает фонарик; попробуйте завершить сканирование и открыть его снова."
                }
            } else {
                // Includes devices selected before a camera switch, and runs
                // after every queued ON even if the AR session has already ended.
                for device in allUsed {
                    do { try device.setEnabled(false) }
                    catch { failure = "Не удалось выключить фонарик. Проверьте Пункт управления." }
                }
            }
            let active = allUsed.contains { $0.active }, result = failure
            DispatchQueue.main.async { completion(active,result) }
        }
    }
}
