import Foundation
import CoreLocation
import CoreMotion

@MainActor final class Sensors: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var observer: Observer?
    @Published var azimuth: Double = 0
    @Published var elevation: Double = 0
    @Published var headingAccuracy: Double = -1
    @Published var locationAccuracy: Double = -1
    @Published var motionReady = false
    @Published var northIsTrue = false
    @Published var message = "Разрешите геопозицию и движение"
    @Published var denied = false
    var axis: AimAxis = .top
    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private var active = false
    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.headingFilter = 1
        location.headingOrientation = .portrait
    }
    func start() {
        active = true
        location.requestWhenInUseAuthorization()
        resumeLocation()
    }
    private func resumeLocation() {
        guard active else { return }
        let authorized = location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways
        denied = location.authorizationStatus == .denied || location.authorizationStatus == .restricted
        if authorized {
            location.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
            beginMotion()
        } else if denied {
            message = "Геопозиция отключена. Введите координаты в настройках."
            beginMotion()
        }
    }
    func beginMotion() {
        guard !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let canUseTrueNorth = observer != nil && frames.contains(.xTrueNorthZVertical)
        let frame: CMAttitudeReferenceFrame = canUseTrueNorth ? .xTrueNorthZVertical : .xMagneticNorthZVertical
        guard frames.contains(frame) else { message = "Недоступен компас для наведения"; return }
        northIsTrue = canUseTrueNorth
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.showsDeviceMovementDisplay = true
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] value, error in
            guard let self else { return }
            guard let value else { self.message = error?.localizedDescription ?? "Датчики недоступны"; self.motionReady = false; return }
            let r = value.attitude.rotationMatrix
            let v = self.axis == .top ? AimMath.direction(north: r.m21, west: r.m22, up: r.m23) : AimMath.direction(north: -r.m31, west: -r.m32, up: -r.m33)
            self.azimuth = v.az
            self.elevation = v.el
            self.motionReady = true
            self.message = self.northIsTrue ? "Истинный север" : "Магнитный север · точность ограничена"
        }
    }
    func stop() {
        active = false
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
        motion.stopDeviceMotionUpdates()
        motionReady = false
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { resumeLocation() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last, value.horizontalAccuracy >= 0, abs(value.timestamp.timeIntervalSinceNow) < 60 else { return }
        observer = Observer(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude, altitudeM: max(-500, value.altitude))
        locationAccuracy = value.horizontalAccuracy
        if !northIsTrue { motion.stopDeviceMotionUpdates(); beginMotion() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) { headingAccuracy = newHeading.headingAccuracy }
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { message = error.localizedDescription }
}
