import CoreImage
import Foundation
import MangaKitchenCore

actor MaskedImageCompositor {
    private let metal: MetalContext

    init(metal: MetalContext) {
        self.metal = metal
    }

    func composite(
        sourceURL: URL,
        generatedURL: URL,
        maskURL: URL,
        outputURL: URL
    ) throws {
        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        guard let source = CIImage(contentsOf: sourceURL, options: options),
              let generated = CIImage(contentsOf: generatedURL, options: options),
              let mask = CIImage(contentsOf: maskURL, options: options),
              !source.extent.isEmpty else {
            throw ImageProcessingError.unreadableImage(sourceURL)
        }

        let target = CGRect(origin: .zero, size: source.extent.size)
        let normalizedSource = normalize(source, to: target)
        let normalizedGenerated = normalize(generated, to: target)
        let normalizedMask = normalize(mask, to: target)
        let composited = normalizedGenerated.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: normalizedSource,
                kCIInputMaskImageKey: normalizedMask
            ]
        ).cropped(to: target)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try metal.coreImageContext.writePNGRepresentation(
                of: composited,
                to: outputURL,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        } catch {
            throw ImageProcessingError.cannotCreateOutput(outputURL)
        }
    }

    private func normalize(_ image: CIImage, to target: CGRect) -> CIImage {
        let translated = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY
        ))
        guard translated.extent.width > 0, translated.extent.height > 0 else { return translated }
        return translated.transformed(by: CGAffineTransform(
            scaleX: target.width / translated.extent.width,
            y: target.height / translated.extent.height
        )).cropped(to: target)
    }
}
