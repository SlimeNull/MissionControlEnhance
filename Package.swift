// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MissionControlEnhance",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MissionControlEnhance",
            path: "Sources/MissionControlEnhance",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
