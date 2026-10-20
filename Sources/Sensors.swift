import Foundation
import CoreLocation
import CoreMotion

@MainActor final class Sensors: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var observer: Observer?
    private(set) var azimuth: Double = 0
    private(set) var elevation: Double = 0
    @Published var headingAccuracy: Double = -1
    @Published var locationAccuracy: Double = -1
    @Published var motionReady = false
    @Published var northIsTrue = false
    @Published var message = "Разрешите геопозицию и движение"
    @Published var denied = false
    var axis: AimAxis = .top {
        didSet {
            guard oldValue != axis else { return }
            if let basis = lastBasis { apply(basis) } else { motionReady = false }
        }
    }
    private(set) var lastBasis: DeviceBasis?
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
            self.apply(.init(x:.init(north:r.m11,west:r.m12,up:r.m13),y:.init(north:r.m21,west:r.m22,up:r.m23),z:.init(north:r.m31,west:r.m32,up:r.m33)))
            let text=self.northIsTrue ? "Истинный север" : "Магнитный север · точность ограничена"
            if self.message != text { self.message=text }
        }
    }
    private func apply(_ basis: DeviceBasis) {
        objectWillChange.send()
        lastBasis = basis
        let v = AimMath.direction(axis:axis,basis:basis)
        azimuth = v.az; elevation = v.el; if !motionReady { motionReady = true }
    }
    #if DEBUG
    func preview(azimuth: Double, elevation: Double, axis: AimAxis) {
        self.axis = axis
        northIsTrue = true; headingAccuracy = 5
        message = "Учебная ориентация симулятора"
        apply(AimMath.pose(azimuth:azimuth,elevation:elevation,aiming:axis))
    }
    #endif
    func stop() {
        active = false
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
        motion.stopDeviceMotionUpdates()
        motionReady = false
        lastBasis = nil
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
