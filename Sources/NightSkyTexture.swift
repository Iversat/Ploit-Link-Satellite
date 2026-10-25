import MetalKit

/// Precompressed ASTC mip chain. Never expands the 16K map into a 512 MB bitmap.
enum NightSkyTexture {
    static let width = 16384, height = 8192, block = 5, levels = 15

    struct Level {
        let data: Data
        let width: Int, height: Int, rowBytes: Int
    }
    static func level(_ index: Int, bundle: Bundle = .main) throws -> Level {
        guard (0..<levels).contains(index),
              let url = bundle.url(forResource:"night-sky-\(index)",withExtension:"astc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf:url,options:.mappedIfSafe)
        let w = max(1,width >> index), h = max(1,height >> index)
        let row = ((w+block-1)/block)*16
        guard data.count == 16 + row*((h+block-1)/block),
              Array(data.prefix(7)) == [0x13,0xAB,0xA1,0x5C,5,5,1] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func dimension(_ offset: Int) -> Int {
            Int(data[offset]) | (Int(data[offset+1]) << 8) | (Int(data[offset+2]) << 16)
        }
        guard dimension(7) == w, dimension(10) == h, dimension(13) == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Level(data:data,width:w,height:h,rowBytes:row)
    }
    static func load(device: MTLDevice) throws -> MTLTexture {
        #if targetEnvironment(simulator)
        // Intel simulators lack ASTC. Physical supported iPhones all support it.
        if !device.supportsFamily(.apple2) {
            guard let url = Bundle.main.url(forResource:"night-sky-panorama",withExtension:"jpg") else { throw CocoaError(.fileNoSuchFile) }
            return try MTKTextureLoader(device:device).newTexture(URL:url,options:[.SRGB:true,.origin:MTKTextureLoader.Origin.topLeft.rawValue,.generateMipmaps:true,.textureUsage:MTLTextureUsage.shaderRead.rawValue])
        }
        #endif
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.astc_5x5_srgb,width:width,height:height,mipmapped:true)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor:descriptor) else { throw CocoaError(.coderInvalidValue) }
        for index in 0..<levels {
            try autoreleasepool {
                let part = try level(index)
                part.data.withUnsafeBytes { bytes in
                    texture.replace(region:MTLRegionMake2D(0,0,part.width,part.height),mipmapLevel:index,
                                    withBytes:bytes.baseAddress!.advanced(by:16),bytesPerRow:part.rowBytes)
                }
            }
        }
        return texture
    }
}
