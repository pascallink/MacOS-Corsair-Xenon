// swift-tools-version:5.9
// XeneonEdge for macOS — native driver & dashboard for the CORSAIR XENEON EDGE.
import PackageDescription

let package = Package(
    name: "XeneonEdge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "XeneonEdgeKit", targets: ["XeneonEdgeKit"]),
        .executable(name: "XeneonEdgeApp", targets: ["XeneonEdgeApp"]),
        .executable(name: "ClaudeUsageWidget", targets: ["ClaudeUsageWidget"]),
        .executable(name: "xeneonctl", targets: ["xeneonctl"]),
    ],
    targets: [
        .target(
            name: "XeneonEdgeKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "XeneonEdgeApp",
            dependencies: ["XeneonEdgeKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "ClaudeUsageWidget",
            dependencies: ["XeneonEdgeKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "xeneonctl",
            dependencies: ["XeneonEdgeKit"]
        ),
        .testTarget(
            name: "XeneonEdgeKitTests",
            dependencies: ["XeneonEdgeKit"]
        ),
    ]
)
