// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shaderdesk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Shaderdesk",
            path: "Sources/Shaderdesk"
        ),
    ],
    swiftLanguageModes: [.v5]
)
