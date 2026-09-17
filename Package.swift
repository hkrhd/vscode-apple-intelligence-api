// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "vscode-apple-intelligence-api",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "apple-intelligence-api", targets: ["AppleIntelligenceAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0")
    ],
    targets: [
        .executableTarget(
            name: "AppleIntelligenceAPI",
            dependencies: [.product(name: "Hummingbird", package: "hummingbird")],
            path: "Sources/AppleIntelligenceAPI"
        )
    ]
)
