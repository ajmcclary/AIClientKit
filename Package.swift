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
        .library(name: "AIClientStorage", targets: ["AIClientStorage"]),
        .library(name: "AIModelCatalog", targets: ["AIModelCatalog"]),
        .library(name: "AIModelCatalogStorage", targets: ["AIModelCatalogStorage"]),
        .library(name: "AIClientAnthropic", targets: ["AIClientAnthropic"]),
        .library(name: "AIClientOpenAI", targets: ["AIClientOpenAI"]),
        .library(name: "AIClientModelDiscovery", targets: ["AIClientModelDiscovery"]),
        .library(name: "AIClientOpenAICompatible", targets: ["AIClientOpenAICompatible"])
    ],
    dependencies: [
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic", exact: "2.2.2")
    ],
    targets: [
        .target(name: "AIClientKit", swiftSettings: settings),
        .target(name: "AIClientHTTP", swiftSettings: settings),
        .target(name: "AIClientStorage", dependencies: ["AIClientKit"], swiftSettings: settings),
        .target(name: "AIModelCatalog", dependencies: ["AIClientKit"], swiftSettings: settings),
        .target(name: "AIModelCatalogStorage", dependencies: ["AIModelCatalog", "AIClientKit", "AIClientStorage"], swiftSettings: settings),
        .target(name: "AIClientOpenAI", dependencies: ["AIClientKit", "AIClientHTTP", "AIModelCatalog"], swiftSettings: settings),
        .target(name: "AIClientAnthropic", dependencies: ["AIClientKit", "AIClientHTTP", "AIClientModelDiscovery", "AIModelCatalog", .product(name: "SwiftAnthropic", package: "SwiftAnthropic")], swiftSettings: settings),
        .target(name: "AIClientModelDiscovery", dependencies: ["AIClientKit", "AIClientHTTP"], swiftSettings: settings),
        .target(name: "AIClientOpenAICompatible", dependencies: ["AIClientKit", "AIClientHTTP"], swiftSettings: settings),
        .testTarget(name: "AIClientKitTests", dependencies: ["AIClientKit"], swiftSettings: settings),
        .testTarget(name: "AIClientStorageTests", dependencies: ["AIClientStorage", "AIClientKit"], swiftSettings: settings),
        .testTarget(name: "AIModelCatalogTests", dependencies: ["AIModelCatalog", "AIModelCatalogStorage", "AIClientKit", "AIClientStorage"], resources: [.process("Fixtures")], swiftSettings: settings),
        .testTarget(name: "AIClientOpenAITests", dependencies: ["AIClientOpenAI", "AIClientKit", "AIClientHTTP"], resources: [.process("Fixtures")], swiftSettings: settings),
        .testTarget(name: "AIClientAnthropicTests", dependencies: ["AIClientAnthropic", "AIClientKit", "AIClientHTTP"], swiftSettings: settings),
        .testTarget(name: "AIClientOpenAICompatibleTests", dependencies: ["AIClientOpenAICompatible", "AIClientHTTP", "AIClientKit"], swiftSettings: settings),
        .testTarget(name: "AIClientModelDiscoveryTests", dependencies: ["AIClientModelDiscovery", "AIClientHTTP", "AIClientKit"], swiftSettings: settings)
    ]
)
