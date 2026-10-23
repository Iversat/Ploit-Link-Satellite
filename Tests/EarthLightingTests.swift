import XCTest
import SceneKit
@testable import PloitSatellite

final class EarthLightingTests: XCTestCase {
    private func elevation(latitude: Double,longitude: Double,date: Date) -> Double {
        let sun=SolarPosition.direction(at:date),r=Double.pi/180
        let cosine=cos(latitude*r)*cos(longitude*r)*sun.x
            + cos(latitude*r)*sin(longitude*r)*sun.y + sin(latitude*r)*sun.z
        return asin(min(1,max(-1,cosine)))/r
    }
    func testEveningHemisphereFollowsUTCAndLongitude() throws {
        let format=ISO8601DateFormatter()
        let evening=try XCTUnwrap(format.date(from:"2026-10-23T16:38:00Z"))
        let day=try XCTUnwrap(format.date(from:"2026-10-23T09:00:00Z"))
        XCTAssertLessThan(elevation(latitude:48.708,longitude:44.513,date:evening),-25)
        XCTAssertLessThan(elevation(latitude:55.75,longitude:37.62,date:evening),-20)
        XCTAssertGreaterThan(elevation(latitude:40,longitude:-74,date:evening),35)
        XCTAssertGreaterThan(elevation(latitude:48.708,longitude:44.513,date:day),25)
    }
    @MainActor func testNightCameraDoesNotAdaptExposureToDarkHemisphere() {
        let camera=SCNCamera()
        camera.wantsHDR=true; camera.wantsExposureAdaptation=true; camera.bloomIntensity=2
        EarthLighting.configure(camera:camera)
        XCTAssertFalse(camera.wantsExposureAdaptation)
        XCTAssertFalse(camera.wantsHDR)
        XCTAssertEqual(camera.bloomIntensity,0)
    }
    @MainActor func testHomeRotationPreservesGeographicSunAngleBeforeRendering() throws {
        let date=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-10-23T16:38:00Z"))
        let scene=SCNScene(),globe=SCNNode(geometry:SCNSphere(radius:1)),camera=SCNNode()
        let material=SCNMaterial(); globe.geometry?.firstMaterial=material
        scene.rootNode.addChildNode(globe); scene.rootNode.addChildNode(camera)
        EarthLighting.configure(material)
        let lat=48.708,lon=44.513,r=Double.pi/180
        let observerNormal=SCNVector3(Float(cos(lat*r)*sin(lon*r)),Float(sin(lat*r)),Float(cos(lat*r)*cos(lon*r)))
        let expected=sin(elevation(latitude:lat,longitude:lon,date:date)*r)
        for cameraYaw in [0.0,0.7,-1.2] {
            globe.eulerAngles=SCNVector3(Float((lat-50)*r),Float(-lon*r),0)
            camera.eulerAngles=SCNVector3(0,Float(cameraYaw),0)
            EarthLighting.update(globe:globe,camera:camera,date:date,animated:false)
            let sun=try XCTUnwrap(material.value(forKey:"sunDirection") as? NSValue).scnVector3Value
            let normal=camera.convertVector(globe.convertVector(observerNormal,to:nil),from:nil)
            let dot=Double(sun.x*normal.x+sun.y*normal.y+sun.z*normal.z)
            XCTAssertEqual(dot,expected,accuracy:0.00001)
            XCTAssertLessThan(dot,0,"Changing the view must not turn the observer's night into daylight")
        }
    }
}
