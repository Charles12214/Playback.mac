// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Playback",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Playback", targets: ["Playback"])],
    targets: [
        .executableTarget(
            name: "Playback",
            path: "Sources/Playback",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
