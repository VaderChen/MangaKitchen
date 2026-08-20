import CoreGraphics
import Foundation
@preconcurrency import Metal
import MangaKitchenCore

public actor MetalBubbleCleaner {
    private let metal: MetalContext
    private let pipeline: any MTLComputePipelineState

    public init(metal: MetalContext) throws {
        self.metal = metal
        do {
            let library = try metal.device.makeLibrary(source: Self.kernelSource, options: nil)
            guard let function = library.makeFunction(name: "clean_dialogue_pixels") else {
                throw ImageProcessingError.metalPipelineCreation
            }
            self.pipeline = try metal.device.makeComputePipelineState(function: function)
        } catch let error as ImageProcessingError {
            throw error
        } catch {
            throw ImageProcessingError.metalLibraryCompilation(error.localizedDescription)
        }
    }

    public func clean(
        sourceURL: URL,
        maskURL: URL,
        outputURL: URL,
        progress: @escaping InferenceProgress
    ) async throws {
        try Task.checkCancellation()
        let sourceImage = try CGImageIO.load(from: sourceURL)
        let maskImage = try CGImageIO.load(from: maskURL)
        let width = sourceImage.width
        let height = sourceImage.height
        guard width == maskImage.width, height == maskImage.height else {
            throw ImageProcessingError.cannotCreateBitmap
        }

        let sourceTexture = try makeReadTexture(from: sourceImage)
        let maskTexture = try makeReadTexture(from: maskImage)
        // 取樣要避開的範圍：遮罩往外膨脹幾像素，把抗鋸齒殘留整圈排除。
        // 只用「離目前像素夠遠」不夠 —— 字內部的像素往外取樣照樣會落進殘留圈。
        let exclusionTexture = try makeExclusionTexture(
            from: maskImage,
            radius: Self.sampleInset
        )
        let outputTexture = try makeTexture(
            width: width,
            height: height,
            usage: [.shaderRead, .shaderWrite],
            storageMode: .shared
        )
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            throw ImageProcessingError.metalCommandFailed
        }
        progress(0.2)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ImageProcessingError.metalCommandFailed
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(maskTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setTexture(exclusionTexture, index: 3)
        var searchRadius = UInt32(min(192, max(24, min(width, height) / 12)))
        encoder.setBytes(&searchRadius, length: MemoryLayout<UInt32>.size, index: 0)

        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()
        guard commandBuffer.status == .completed else {
            throw ImageProcessingError.metalCommandFailed
        }
        try Task.checkCancellation()
        progress(0.85)

        try writePNG(
            from: outputTexture,
            width: width,
            height: height,
            colorSpace: colorSpace,
            to: outputURL
        )
        progress(1)
    }

    private func writePNG(
        from texture: any MTLTexture,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace,
        to outputURL: URL
    ) throws {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ).union(.byteOrder32Big),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        try CGImageIO.writePNG(image, to: outputURL)
    }

    private func makeReadTexture(from image: CGImage) throws -> any MTLTexture {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ).union(.byteOrder32Big)
        let imageWasDrawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard imageWasDrawn else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        let texture = try makeTexture(
            width: width,
            height: height,
            usage: .shaderRead,
            storageMode: .shared
        )
        pixels.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    private func makeTexture(
        width: Int,
        height: Int,
        usage: MTLTextureUsage,
        storageMode: MTLStorageMode = .private
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        guard let texture = metal.device.makeTexture(descriptor: descriptor) else {
            throw ImageProcessingError.metalTextureCreation
        }
        return texture
    }

    /// 取樣時要避開的距離（像素）。
    private static let sampleInset = 3

    /// 把遮罩膨脹後做成單通道材質，供 shader 判斷哪些像素不能當樣本。
    private func makeExclusionTexture(from maskImage: CGImage, radius: Int) throws -> any MTLTexture {
        let width = maskImage.width
        let height = maskImage.height
        var gray = [UInt8](repeating: 0, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(maskImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageProcessingError.cannotCreateBitmap }

        let dilated = MaskDilation.dilated(
            gray.map { $0 > 127 },
            width: width,
            height: height,
            radius: radius
        )
        var bytes = [UInt8](repeating: 0, count: width * height)
        for index in dilated.indices where dilated[index] { bytes[index] = 255 }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = metal.device.makeTexture(descriptor: descriptor) else {
            throw ImageProcessingError.cannotCreateBitmap
        }
        bytes.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: width
            )
        }
        return texture
    }

    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void clean_dialogue_pixels(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::read> mask [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        texture2d<float, access::read> exclusion [[texture(3)]],
        constant uint &searchRadius [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
        float4 original = source.read(gid);
        if (mask.read(gid).r <= 0.0f) {
            output.write(original, gid);
            return;
        }

        uint luminanceHistogram[16] = {};
        uint sampleCount = 0;
        uint sampledRings = 0;
        int2 maximumPoint = int2(source.get_width() - 1, source.get_height() - 1);
        const uint directions = 24;
        const uint rings = 8;
        for (uint ring = 1; ring <= rings; ++ring) {
            float radius = min(float(searchRadius), exp2(float(ring)));
            uint ringSampleCount = 0;
            for (uint index = 0; index < directions; ++index) {
                float angle = 6.28318530718f * float(index) / float(directions);
                int2 point = int2(round(float2(gid) + float2(cos(angle), sin(angle)) * radius));
                uint2 coordinate = uint2(clamp(point, int2(0), maximumPoint));
                if (exclusion.read(coordinate).r <= 0.0f) {
                    float3 color = source.read(coordinate).rgb;
                    float luminance = dot(color, float3(0.299f, 0.587f, 0.114f));
                    uint bin = min(15u, uint(clamp(luminance, 0.0f, 1.0f) * 15.999f));
                    luminanceHistogram[bin] += 1;
                    sampleCount += 1;
                    ringSampleCount += 1;
                }
            }
            sampledRings = ring;
            if (sampleCount >= directions || radius >= float(searchRadius)) break;
        }

        if (sampleCount == 0) {
            output.write(original, gid);
            return;
        }

        // 百分位數只看亮度排序；少量掃描亮點就可能把每個像素推到不同色階，
        // 大面積填補後會形成雜紋。改取出現次數最多的色階，與 CPU 路徑一致；
        // 票數相同時保留較亮者，避免線稿色階勝出。
        uint dominantBin = 0;
        uint dominantCount = 0;
        for (uint bin = 0; bin < 16; ++bin) {
            if (luminanceHistogram[bin] >= dominantCount) {
                dominantBin = bin;
                dominantCount = luminanceHistogram[bin];
            }
        }

        float4 replacementSum = float4(0.0f);
        float replacementWeight = 0.0f;
        for (uint ring = 1; ring <= sampledRings; ++ring) {
            float radius = min(float(searchRadius), exp2(float(ring)));
            for (uint index = 0; index < directions; ++index) {
                float angle = 6.28318530718f * float(index) / float(directions);
                int2 point = int2(round(float2(gid) + float2(cos(angle), sin(angle)) * radius));
                uint2 coordinate = uint2(clamp(point, int2(0), maximumPoint));
                if (exclusion.read(coordinate).r > 0.0f) continue;
                float4 candidate = source.read(coordinate);
                float luminance = dot(candidate.rgb, float3(0.299f, 0.587f, 0.114f));
                uint bin = min(15u, uint(clamp(luminance, 0.0f, 1.0f) * 15.999f));
                if (bin != dominantBin) continue;
                float weight = 1.0f / float(ring);
                replacementSum += candidate * weight;
                replacementWeight += weight;
            }
        }
        float4 replacement = replacementWeight > 0.0f
            ? replacementSum / replacementWeight
            : original;
        output.write(float4(replacement.rgb, original.a), gid);
    }
    """
}
