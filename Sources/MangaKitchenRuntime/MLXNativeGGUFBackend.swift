import Foundation

public struct MLXNativeGGUFBackend: Sendable {
    public init() {}

    public func inspect(fileURL: URL) throws -> GGUFBackendInspection {
        try MLXGGUFLoader.inspect(from: fileURL)
    }

    public func canMaterialize(_ inspection: GGUFBackendInspection) -> Bool {
        inspection.unsupportedTypes.isEmpty
            && inspection.tensors.allSatisfy {
                GGUFStoragePolicy.isMaterializable($0.type)
            }
    }
}
