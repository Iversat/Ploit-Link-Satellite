import SwiftUI
import SceneKit

struct EarthView: UIViewRepresentable {
    // Projection of the observer after the fixed geographic framing below.
    static let observerScreenY = 0.5 - (sin(50 * Double.pi/180) - 0.60)
        / (2.3 - cos(50 * Double.pi/180)) / tan(22.5 * Double.pi/180) / 2
    var active=true
    var latitude: Double = 35
    var longitude: Double = 35
    private var lightingDate: Date {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-home-night") {
            return ISO8601DateFormatter().date(from:"2026-10-21T00:00:00Z")!
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-home-evening") {
            return ISO8601DateFormatter().date(from:"2026-10-23T16:38:00Z")!
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-home-day") {
            return ISO8601DateFormatter().date(from:"2026-10-23T09:00:00Z")!
        }
        #endif
        return Date()
    }
    final class Coordinator: NSObject {
        var latitude: Double?; var longitude: Double?
        var lastLightingDate=Date.distantPast
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SCNView {
        let view = EarthRenderView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.antialiasingMode = .multisampling4X
        view.contentScaleFactor=UIScreen.main.nativeScale
        view.preferredFramesPerSecond = 30
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 160
        let material = SCNMaterial()
        EarthTextures.apply(to:material,in:view)
        EarthLighting.configure(material)
        sphere.firstMaterial = material
        let globe = SCNNode(geometry: sphere)
        globe.name = "earth"
        // SCNSphere front samples the texture midpoint (0 deg longitude).
        // Keep the observer toward the upper visible hemisphere.
        // The camera already looks down toward the globe, so latitude is offset.
        globe.eulerAngles = SCNVector3(Float((latitude - 50) * .pi / 180), Float(-longitude * .pi / 180), 0)
        globe.position = SCNVector3(0, -0.60, 0)
        scene.rootNode.addChildNode(globe)
        StarField.add(to:scene.rootNode)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 45
        camera.camera?.projectionDirection = .vertical
        EarthLighting.configure(camera:camera.camera!)
        camera.camera?.zNear = 0.1
        camera.position = SCNVector3(0,0,2.3)
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        EarthLighting.update(globe:globe,camera:camera,date:lightingDate,animated:false)
        context.coordinator.latitude=latitude; context.coordinator.longitude=longitude
        context.coordinator.lastLightingDate=lightingDate
        view.isPlaying = false
        return view
    }
    static func dismantleUIView(_ view: SCNView,coordinator: Coordinator) {
        view.isPlaying=false; view.delegate=nil; view.scene=nil
    }
    func updateUIView(_ uiView: SCNView, context: Context) {
        guard active else { return }
        // Geographic rotation and sunlight must use the same transforms in the
        // same frame. This static backdrop does not need a second frame loop.
        let date=lightingDate
        let previous=context.coordinator
        let moved=(previous.latitude.map { abs($0-latitude)>=0.01 } ?? true)
            || (previous.longitude.map { abs(AimMath.wrap($0-longitude))>=0.01 } ?? true)
        guard moved || abs(date.timeIntervalSince(previous.lastLightingDate))>=1,
              let node=uiView.scene?.rootNode.childNode(withName:"earth",recursively:false),
              let camera=uiView.pointOfView else { return }
        SCNTransaction.begin(); SCNTransaction.disableActions=true
        if moved {
            node.eulerAngles=SCNVector3(Float((latitude-50) * .pi/180),Float(-longitude * .pi/180),0)
            previous.latitude=latitude; previous.longitude=longitude
        }
        EarthLighting.update(globe:node,camera:camera,date:date,animated:false)
        SCNTransaction.commit()
        previous.lastLightingDate=date
        uiView.setNeedsDisplay()
    }
}
