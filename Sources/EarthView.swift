import SwiftUI
import SceneKit

struct EarthView: UIViewRepresentable {
    var latitude: Double = 35
    var longitude: Double = 35
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 128
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.black
        material.emission.contents = UIImage(named: "earth-night.jpg")
        material.emission.intensity = 1.65
        material.lightingModel = .constant
        sphere.firstMaterial = material
        let globe = SCNNode(geometry: sphere)
        globe.name = "earth"
        // SceneKit sphere longitude seam is at -Z; camera looks down -Z.
        globe.eulerAngles = SCNVector3(Float(latitude * .pi / 180), Float((-longitude - 90) * .pi / 180), 0)
        globe.position = SCNVector3(0, -0.60, 0)
        scene.rootNode.addChildNode(globe)
        let atmosphere = SCNSphere(radius: 1.015)
        atmosphere.segmentCount = 128
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = UIColor.clear
        glow.isDoubleSided = true
        glow.blendMode = .add
        glow.writesToDepthBuffer = false
        glow.shaderModifiers = [.fragment: "float rim = pow(1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view))), 5.0); _output.color = float4(0.10,0.55,1.0,1.0) * rim * 0.65;"]
        atmosphere.firstMaterial = glow
        let halo = SCNNode(geometry: atmosphere)
        globe.addChildNode(halo)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 45
        camera.camera?.projectionDirection = .vertical
        camera.camera?.zNear = 0.01
        camera.position = SCNVector3(0,0,2.3)
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        view.isPlaying = false
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let node = uiView.scene?.rootNode.childNode(withName: "earth", recursively: false) else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 1.2
        node.eulerAngles = SCNVector3(Float(latitude * .pi / 180),Float((-longitude - 90) * .pi / 180),0)
        SCNTransaction.commit()
        uiView.setNeedsDisplay()
    }
}
