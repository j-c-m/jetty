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
            name: "Jetty",
            dependencies: ["CPty"],
            path: "Sources/Jetty",
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
            ]
        ),
        .executableTarget(
            name: "JettyApp",
            dependencies: ["Jetty"],
            path: "Sources/JettyApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .testTarget(
            name: "JettyTests",
            dependencies: ["Jetty"]
        ),
    ]
)
