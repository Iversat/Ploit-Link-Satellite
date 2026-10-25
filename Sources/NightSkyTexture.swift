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
        // Use the same NASA map through the simulator-compatible image loader,
        // within its 8K texture limit. Physical iPhones use the 16K ASTC chain.
        guard let url = Bundle.main.url(forResource:"night-sky-simulator",withExtension:"jpg") else { throw CocoaError(.fileNoSuchFile) }
        return try MTKTextureLoader(device:device).newTexture(URL:url,options:[.SRGB:true,.origin:MTKTextureLoader.Origin.topLeft.rawValue,.generateMipmaps:true,.textureUsage:MTLTextureUsage.shaderRead.rawValue])
        #else
        // Supported physical iPhones expose Apple3 or later and use all 16K.
        let firstLevel = device.supportsFamily(.apple3) ? 0 : 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.astc_5x5_srgb,width:width >> firstLevel,height:height >> firstLevel,mipmapped:true)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor:descriptor) else { throw CocoaError(.coderInvalidValue) }
        for index in firstLevel..<levels {
            try autoreleasepool {
                let part = try level(index)
                part.data.withUnsafeBytes { bytes in
                    texture.replace(region:MTLRegionMake2D(0,0,part.width,part.height),mipmapLevel:index-firstLevel,
                                    withBytes:bytes.baseAddress!.advanced(by:16),bytesPerRow:part.rowBytes)
                }
            }
        }
        return texture
        #endif
    }
}
