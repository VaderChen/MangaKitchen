// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MangaKitchen",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MangaKitchen", targets: ["MangaKitchenApp"]),
        .library(name: "MangaKitchenCore", targets: ["MangaKitchenCore"]),
        .library(name: "MangaKitchenApplication", targets: ["MangaKitchenApplication"]),
        .library(name: "MangaKitchenRuntime", targets: ["MangaKitchenRuntime"])
    ],
    dependencies: [
        .package(path: "Vendor/mlx-swift-lm"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            exact: "0.31.6"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            exact: "1.1.9"
        ),
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.101.3"
        )
    ],
    targets: [
        .target(name: "MangaKitchenCore"),
        .target(
            name: "MangaKitchenApplication",
            dependencies: ["MangaKitchenCore"]
        ),
        .target(
            name: "MangaKitchenRuntime",
            dependencies: [
                "MangaKitchenCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .executableTarget(
            name: "MangaKitchenApp",
            dependencies: [
                "MangaKitchenCore",
                "MangaKitchenApplication",
                "MangaKitchenRuntime",
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ],
            exclude: [
                "Resources/AppIcon"
            ],
            resources: [
                .copy("Resources/Models"),
                .copy("Resources/WebUI")
            ]
        ),
        .executableTarget(
            name: "GGUFSmoke",
            dependencies: ["MangaKitchenCore", "MangaKitchenRuntime"]
        ),
        .testTarget(
            name: "MangaKitchenRuntimeTests",
            dependencies: [
                "MangaKitchenCore",
                "MangaKitchenRuntime",
                .product(name: "MLX", package: "mlx-swift")
            ]
        )
    ]
)
