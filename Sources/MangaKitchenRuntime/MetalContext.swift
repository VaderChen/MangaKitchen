import CoreImage
import Foundation
@preconcurrency import Metal

public final class MetalContext: @unchecked Sendable {
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let coreImageContext: CIContext

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalContextError.deviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalContextError.commandQueueUnavailable
        }
        self.device = device
        self.commandQueue = commandQueue
        self.coreImageContext = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ]
        )
    }
}

public enum MetalContextError: LocalizedError, Sendable {
    case deviceUnavailable
    case commandQueueUnavailable

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable: "這台 Mac 沒有可用的 Metal 裝置。"
        case .commandQueueUnavailable: "無法建立 Metal Command Queue。"
        }
    }
}
