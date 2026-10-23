import SwiftUI
import SceneKit

struct EarthView: UIViewRepresentable {
    var active=true
    var latitude: Double = 35
    var longitude: Double = 35
    private var lightingDate: Date {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-home-night") {
            return ISO8601DateFormatter().date(from:"2026-10-21T00:00:00Z")!
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
        camera.camera?.wantsHDR = true
        camera.camera?.exposureOffset = -0.6
        camera.camera?.bloomIntensity = 0
        camera.camera?.zNear = 0.1
        camera.position = SCNVector3(0,0,2.3)
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        EarthLighting.update(globe:globe,camera:camera,date:lightingDate)
        view.isPlaying = false
        return view
    }
    static func dismantleUIView(_ view: SCNView,coordinator: Coordinator) {
        view.isPlaying=false; view.delegate=nil; view.scene=nil
    }
    func updateUIView(_ uiView: SCNView, context: Context) {
        guard active else { return }
        // The mostly static home backdrop needs no second continuous frame loop.
        // Update its sunlight with the regular model refresh, on the main thread.
        let date=lightingDate
        if abs(date.timeIntervalSince(context.coordinator.lastLightingDate))>=1,
           let globe=uiView.scene?.rootNode.childNode(withName:"earth",recursively:false),let camera=uiView.pointOfView {
            SCNTransaction.begin(); SCNTransaction.disableActions=true
            EarthLighting.update(globe:globe,camera:camera,date:date)
            SCNTransaction.commit()
            context.coordinator.lastLightingDate=date
            uiView.setNeedsDisplay()
        }
        let previous=context.coordinator
        if let lat=previous.latitude, let lon=previous.longitude,
           abs(lat-latitude)<0.01, abs(AimMath.wrap(lon-longitude))<0.01 { return }
        previous.latitude=latitude; previous.longitude=longitude
        guard let node = uiView.scene?.rootNode.childNode(withName: "earth", recursively: false) else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 1.2
        node.eulerAngles = SCNVector3(Float((latitude - 50) * .pi / 180),Float(-longitude * .pi / 180),0)
        SCNTransaction.commit()
        uiView.setNeedsDisplay()
    }
}
