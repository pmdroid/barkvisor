// swift-tools-version:6.2.3
import PackageDescription

// NOTE: PackageDescription.SupportedPlatform has no `.linux` case; Linux builds
// are unconstrained by `platforms` and work when the toolchain targets Linux.
// Helper / HelperProtocol targets are macOS-only (NSXPC / SMJobBless).

var coreDependencies: [Target.Dependency] = [
    .product(name: "GRDB", package: "GRDB.swift"),
    .product(name: "JWTKit", package: "jwt-kit"),
    .product(name: "Yams", package: "Yams"),
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOPosix", package: "swift-nio"),
    .product(name: "Logging", package: "swift-log"),
    .product(name: "SwiftSentry", package: "swift-sentry"),
    .product(name: "Crypto", package: "swift-crypto"),
    .product(name: "X509", package: "swift-certificates"),
]

var testDependencies: [Target.Dependency] = [
    "BarkVisor",
    "BarkVisorCore",
    .product(name: "GRDB", package: "GRDB.swift"),
    .product(name: "Yams", package: "Yams"),
    // For ImageChecksumTests (and any CryptoKit/Crypto usage) on Linux.
    .product(name: "Crypto", package: "swift-crypto"),
    .product(name: "X509", package: "swift-certificates"),
    .product(name: "NIOSSL", package: "swift-nio-ssl"),
    .product(name: "NIOPosix", package: "swift-nio"),
    .product(name: "AsyncHTTPClient", package: "async-http-client"),
    .product(name: "JWTKit", package: "jwt-kit"),
]

#if os(macOS)
coreDependencies.insert("BarkVisorHelperProtocol", at: 0)
testDependencies.append("BarkVisorHelperProtocol")
#endif

var packageTargets: [Target] = []

#if os(macOS)
packageTargets.append(contentsOf: [
    .target(
        name: "BarkVisorHelperProtocol",
        path: "Sources/BarkVisorHelperProtocol",
    ),
    .executableTarget(
        name: "BarkVisorHelper",
        dependencies: [
            "BarkVisorHelperProtocol",
            .product(name: "Logging", package: "swift-log"),
            .product(name: "SwiftSentry", package: "swift-sentry"),
        ],
        path: "Sources/BarkVisorHelper",
    ),
])
#endif

packageTargets.append(contentsOf: [
    // Core library: services, models, helpers — no Vapor dependency
    .target(
        name: "BarkVisorCore",
        dependencies: coreDependencies,
        path: "Sources/BarkVisorCore",
        resources: [
            .copy("API/openapi.yaml"),
            .copy("API/workloadspec.schema.json"),
        ],
    ),
    // Vapor HTTP layer: controllers, middleware, server
    .target(
        name: "BarkVisor",
        dependencies: [
            "BarkVisorCore",
            .product(name: "Vapor", package: "vapor"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
        ],
        path: "Sources/BarkVisor",
        exclude: [
            "Resources/frontend/dist",
            "Resources/AppIcon.icns",
        ],
    ),
    // Headless daemon entry point (no AppKit/SwiftUI)
    .executableTarget(
        name: "BarkVisorApp",
        dependencies: [
            "BarkVisor",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "SwiftSentry", package: "swift-sentry"),
        ],
        path: "Sources/BarkVisorApp",
    ),
    .testTarget(
        name: "BarkVisorTests",
        dependencies: testDependencies,
        path: "Tests/BarkVisorTests",
    ),
])

let package = Package(
    name: "BarkVisor",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-sentry/swift-sentry.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: packageTargets,
)
