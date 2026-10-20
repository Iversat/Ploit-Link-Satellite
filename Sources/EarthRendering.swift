import SceneKit
import MetalKit

// Share GPU textures between the home scene and orbit explorer. Do not retain a
// second decoded UIImage for each 8K map, or upload it again for each screen.
enum EarthTextures {
    private static let loader = MTLCreateSystemDefaultDevice().map { MTKTextureLoader(device: $0) }
    private static let day = load("earth-day")
    private static let night = load("earth-night")
    private static func load(_ name: String) -> MTLTexture? {
        guard let url=Bundle.main.url(forResource:name,withExtension:"jpg") else { return nil }
        return try? loader?.newTexture(URL:url,options:[.SRGB:true,.generateMipmaps:true])
    }
    static func apply(to material: SCNMaterial) {
        if let day { material.diffuse.contents=day }
        else { material.diffuse.contents=UIImage(named:"earth-day.jpg") }
        if let night { material.emission.contents=night }
        else { material.emission.contents=UIImage(named:"earth-night.jpg") }
        for property in [material.diffuse,material.emission] {
            property.minificationFilter = .linear
            property.magnificationFilter = .linear
            property.mipFilter = .linear
            property.maxAnisotropy = 8
        }
    }
}

class EarthRenderView: SCNView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Match the display instead of stretching a 2x render target on 3x phones.
        contentScaleFactor=window?.screen.nativeScale ?? UIScreen.main.nativeScale
    }
}
