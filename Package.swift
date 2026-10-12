// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Relaunch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Relaunch",
            path: "Sources/Relaunch",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
