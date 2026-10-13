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
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic", exact: "2.2.2"),
        // Tracing 1.7.0 and ServiceContext 1.4.0 both declare ServiceContextModule.
        // Preserve the working SwiftAnthropic/AsyncHTTPClient graph until upstream
        // publishes a mutually compatible pair. Explicit product edges below retain
        // these constraints when SwiftPM resolves this as a transitive dependency.
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", exact: "1.5.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", exact: "1.3.0")
    ],
    targets: [
        .target(name: "AIClientKit", swiftSettings: settings),
        .target(name: "AIClientHTTP", swiftSettings: settings),
        .target(name: "AIClientStorage", dependencies: ["AIClientKit"], swiftSettings: settings),
        .target(name: "AIModelCatalog", dependencies: ["AIClientKit"], swiftSettings: settings),
        .target(name: "AIModelCatalogStorage", dependencies: ["AIModelCatalog", "AIClientKit", "AIClientStorage"], swiftSettings: settings),
        .target(name: "AIClientOpenAI", dependencies: ["AIClientKit", "AIClientHTTP", "AIModelCatalog"], swiftSettings: settings),
        .target(name: "AIClientAnthropic", dependencies: ["AIClientKit", "AIClientHTTP", "AIClientModelDiscovery", "AIModelCatalog", .product(name: "SwiftAnthropic", package: "SwiftAnthropic"), .product(name: "Tracing", package: "swift-distributed-tracing"), .product(name: "ServiceContextModule", package: "swift-service-context")], swiftSettings: settings),
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
