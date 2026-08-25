// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jetty",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Jetty", targets: ["Jetty"]),
        .executable(name: "jetty", targets: ["JettyApp"]),
    ],
    targets: [
        .target(
            name: "CPty",
            path: "Sources/CPty",
            publicHeadersPath: ".",
            linkerSettings: [
                .linkedLibrary("util"),
            ]
        ),
        .target(
            name: "CVt",
            path: "Sources/CVt",
            publicHeadersPath: ".",
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "Jetty",
            dependencies: ["CPty", "CVt"],
            path: "Sources/Jetty",
            resources: [
                .copy("Resources"),
            ],
            swiftSettings: [
                .unsafeFlags(
                    ["-enforce-exclusivity=unchecked"],
                    .when(configuration: .release)
                ),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(
            name: "JettyApp",
            dependencies: ["Jetty"],
            path: "Sources/JettyApp",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .testTarget(
            name: "JettyTests",
            dependencies: ["Jetty", "CVt"]
        ),
    ]
)
