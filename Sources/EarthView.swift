import SwiftUI
import SceneKit

struct EarthView: UIViewRepresentable {
    var latitude: Double = 35
    var longitude: Double = 35
    final class Coordinator { var latitude: Double?; var longitude: Double? }
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
        EarthTextures.apply(to:material)
        material.diffuse.intensity = 0.06
        material.emission.intensity = 1.15
        material.shaderModifiers = [.surface: "_surface.emission.rgb *= float3(1.25, 1.0, 0.45);"]
        material.lightingModel = .constant
        sphere.firstMaterial = material
        let globe = SCNNode(geometry: sphere)
        globe.name = "earth"
        // SCNSphere front samples the texture midpoint (0 deg longitude).
        // Keep the observer toward the upper visible hemisphere, as in the reference.
        // The camera already looks down toward the globe, so latitude is offset.
        globe.eulerAngles = SCNVector3(Float((latitude - 50) * .pi / 180), Float(-longitude * .pi / 180), 0)
        globe.position = SCNVector3(0, -0.60, 0)
        scene.rootNode.addChildNode(globe)
        let atmosphere = SCNSphere(radius: 1.008)
        atmosphere.segmentCount = 160
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = UIColor.clear
        glow.isDoubleSided = false
        glow.blendMode = .add
        glow.writesToDepthBuffer = false
        glow.shaderModifiers = [.fragment: "float rim = pow(1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view))), 8.0); _output.color = float4(0.08,0.40,0.85,1.0) * rim * 0.55;"]
        atmosphere.firstMaterial = glow
        let halo = SCNNode(geometry: atmosphere)
        globe.addChildNode(halo)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 45
        camera.camera?.projectionDirection = .vertical
        camera.camera?.wantsHDR = true
        camera.camera?.exposureOffset = -0.6
        camera.camera?.bloomIntensity = 0
        camera.camera?.zNear = 0.01
        camera.position = SCNVector3(0,0,2.3)
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        view.isPlaying = false
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) {
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
