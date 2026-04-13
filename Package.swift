// swift-tools-version:6.2.3
import PackageDescription

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
    ],
    targets: [
        .target(
            name: "BarkVisorHelperProtocol",
            path: "Sources/BarkVisorHelperProtocol"
        ),
        .executableTarget(
            name: "BarkVisorHelper",
            dependencies: [
                "BarkVisorHelperProtocol",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftSentry", package: "swift-sentry"),
            ],
            path: "Sources/BarkVisorHelper"
        ),
        // Core library: services, models, helpers — no Vapor dependency
        .target(
            name: "BarkVisorCore",
            dependencies: [
                "BarkVisorHelperProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/BarkVisorCore"
        ),
        // Vapor HTTP layer: controllers, middleware, server
        .target(
            name: "BarkVisor",
            dependencies: [
                "BarkVisorCore",
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/BarkVisor",
            exclude: [
                "Resources/frontend/dist",
                "Resources/AppIcon.icns",
                "Server/Resources",
            ]
        ),
        // Headless daemon entry point (no AppKit/SwiftUI)
        .executableTarget(
            name: "BarkVisorApp",
            dependencies: [
                "BarkVisor",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftSentry", package: "swift-sentry"),
            ],
            path: "Sources/BarkVisorApp"
        ),
        .testTarget(
            name: "BarkVisorTests",
            dependencies: [
                "BarkVisor",
                "BarkVisorCore",
                "BarkVisorHelperProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Tests/BarkVisorTests"
        ),
    ]
)
