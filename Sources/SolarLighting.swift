import SceneKit

// Low-order solar ephemeris (J2000 mean longitude/anomaly + obliquity).
// Geographic subsolar point, not a camera-relative decorative light.
enum SolarPosition {
    static let earthRate=2 * Double.pi/86164.0905
    static func direction(at date: Date) -> OrbitPoint {
        let jd=date.timeIntervalSince1970/86400+2440587.5,n=jd-2451545.0,r=Double.pi/180
        let mean=(280.460+0.9856474*n).truncatingRemainder(dividingBy:360)*r
        let anomaly=(357.528+0.9856003*n).truncatingRemainder(dividingBy:360)*r
        let longitude=mean+(1.915*sin(anomaly)+0.020*sin(2*anomaly))*r
        let obliquity=(23.439-0.0000004*n)*r
        let rightAscension=atan2(cos(obliquity)*sin(longitude),cos(longitude))
        let declination=asin(sin(obliquity)*sin(longitude))
        let sidereal=(280.46061837+360.98564736629*n).truncatingRemainder(dividingBy:360)*r
        let lon=rightAscension-sidereal
        return OrbitPoint(x:cos(declination)*cos(lon),y:cos(declination)*sin(lon),z:sin(declination))
    }
}

enum EarthLighting {
    static func configure(_ material: SCNMaterial) {
        material.lightingModel = .constant
        material.diffuse.intensity=1; material.emission.intensity=1
        // One opaque surface: no nearly coincident atmosphere shell or depth fighting.
        material.shaderModifiers=[.surface:"""
        #pragma arguments
        float3 sunDirection;
        #pragma body
        float solar = dot(normalize(_surface.normal), normalize(sunDirection));
        float daylight = smoothstep(-0.10, 0.10, solar);
        float diffuseLight = 0.012 + daylight * (0.24 + 0.76 * sqrt(max(0.0, solar)));
        _surface.diffuse.rgb *= diffuseLight;
        _surface.emission.rgb *= float3(1.15, 0.93, 0.62) * (1.0-daylight) * 1.15;
        float rim = pow(1.0-abs(dot(normalize(_surface.normal), normalize(_surface.view))), 5.0);
        _surface.emission.rgb += float3(0.035,0.19,0.40) * rim * (0.12+0.88*daylight);
        """]
        material.setValue(NSValue(scnVector3:SCNVector3(0,0,1)),forKey:"sunDirection")
    }
    static func update(globe: SCNNode,camera: SCNNode,date: Date) {
        let sun=SolarPosition.direction(at:date)
        let local=SCNVector3(Float(sun.y),Float(sun.z),Float(sun.x))
        let world=globe.presentation.convertVector(local,to:nil)
        let eye=camera.presentation.convertVector(world,from:nil)
        globe.geometry?.firstMaterial?.setValue(NSValue(scnVector3:eye),forKey:"sunDirection")
    }
}

enum StarField {
    static func add(to root: SCNNode) {
        // Three batched point meshes, stable positions and brightness: no twinkling.
        for band in 0..<3 {
            let count=[1800,420,80][band]
            let vertices=(0..<count).map { i -> SCNVector3 in
                let y=1-2*(Double(i)+0.5)/Double(count)
                let angle=Double(i)*2.3999632297+Double(band)*1.23,r=sqrt(1-y*y)
                return SCNVector3(Float(35*r*cos(angle)),Float(35*y),Float(35*r*sin(angle)))
            }
            let element=SCNGeometryElement(indices:Array(0..<Int32(count)),primitiveType:.point)
            element.pointSize=CGFloat([1.2,1.9,2.8][band])
            element.minimumPointScreenSpaceRadius=CGFloat([0.45,0.7,1.0][band])
            element.maximumPointScreenSpaceRadius=CGFloat([0.7,1.1,1.6][band])
            let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:[element])
            let material=SCNMaterial(); material.lightingModel = .constant
            material.diffuse.contents=UIColor(white:CGFloat([0.35,0.65,0.95][band]),alpha:1)
            geometry.firstMaterial=material
            let node=SCNNode(geometry:geometry); node.name="stars-\(band)"; root.addChildNode(node)
        }
    }
}
