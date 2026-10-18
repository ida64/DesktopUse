// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeDesktopUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-desktop-use", targets: ["ClaudeDesktopUse"]),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeDesktopUse",
            path: "Sources/ClaudeDesktopUse",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
