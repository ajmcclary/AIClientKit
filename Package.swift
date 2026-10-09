// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "AIClientKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AIClientKit", targets: ["AIClientKit"]),
        .library(name: "AIClientHTTP", targets: ["AIClientHTTP"]),
        .library(name: "AIClientOpenAICompatible", targets: ["AIClientOpenAICompatible"])
    ],
    targets: [
        .target(name: "AIClientKit", swiftSettings: settings),
        .target(name: "AIClientHTTP", swiftSettings: settings),
        .target(name: "AIClientOpenAICompatible", dependencies: ["AIClientKit", "AIClientHTTP"], swiftSettings: settings),
        .testTarget(name: "AIClientKitTests", dependencies: ["AIClientKit"], swiftSettings: settings),
        .testTarget(name: "AIClientOpenAICompatibleTests", dependencies: ["AIClientOpenAICompatible", "AIClientHTTP", "AIClientKit"], swiftSettings: settings)
    ]
)
