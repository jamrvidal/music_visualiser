// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Phosphor",
    platforms: [.macOS("14.2")], // Core Audio process taps arrived in 14.2
    targets: [
        .executableTarget(name: "Phosphor", path: "Sources/Phosphor")
    ]
)
