import CoreGraphics
import CoreImage
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

        let sourceTexture = try makeTexture(width: width, height: height, usage: [.shaderRead])
        let maskTexture = try makeTexture(width: width, height: height, usage: [.shaderRead])
        let outputTexture = try makeTexture(width: width, height: height, usage: [.shaderRead, .shaderWrite])
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        metal.coreImageContext.render(
            CIImage(cgImage: sourceImage),
            to: sourceTexture,
            commandBuffer: nil,
            bounds: bounds,
            colorSpace: colorSpace
        )
        metal.coreImageContext.render(
            CIImage(cgImage: maskImage),
            to: maskTexture,
            commandBuffer: nil,
            bounds: bounds,
            colorSpace: colorSpace
        )
        progress(0.2)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ImageProcessingError.metalCommandFailed
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(maskTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
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

        guard let outputImage = CIImage(
            mtlTexture: outputTexture,
            options: [.colorSpace: colorSpace]
        ) else {
            throw ImageProcessingError.metalTextureCreation
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try metal.coreImageContext.writePNGRepresentation(
                of: outputImage,
                to: outputURL,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        } catch {
            throw ImageProcessingError.cannotCreateOutput(outputURL)
        }
        progress(1)
    }

    private func makeTexture(
        width: Int,
        height: Int,
        usage: MTLTextureUsage
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = metal.device.makeTexture(descriptor: descriptor) else {
            throw ImageProcessingError.metalTextureCreation
        }
        return texture
    }

    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void clean_dialogue_pixels(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::sample> mask [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        constant uint &searchRadius [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
        float4 original = source.read(gid);
        if (mask.read(gid).r < 0.5f) {
            output.write(original, gid);
            return;
        }

        constexpr sampler pointSampler(coord::pixel, address::clamp_to_edge, filter::linear);
        float4 sum = float4(0.0f);
        float weight = 0.0f;
        const uint directions = 24;
        const uint rings = 4;
        for (uint ring = 1; ring <= rings; ++ring) {
            float radius = max(3.0f, float(searchRadius) * float(ring) / float(rings));
            for (uint index = 0; index < directions; ++index) {
                float angle = 6.28318530718f * float(index) / float(directions);
                float2 point = float2(gid) + float2(cos(angle), sin(angle)) * radius;
                float maskValue = mask.sample(pointSampler, point).r;
                if (maskValue < 0.35f) {
                    float localWeight = 1.0f / float(ring);
                    sum += source.sample(pointSampler, point) * localWeight;
                    weight += localWeight;
                }
            }
        }

        float4 replacement = weight > 0.0f ? sum / weight : original;
        output.write(float4(replacement.rgb, original.a), gid);
    }
    """
}
