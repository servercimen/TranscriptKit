// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscriptKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TranscriptKit", targets: ["TranscriptKit"])
    ],
    targets: [
        .target(name: "TranscriptKit"),
        .testTarget(name: "TranscriptKitTests", dependencies: ["TranscriptKit"]),
        .testTarget(name: "TranscriptKitViewTests", dependencies: ["TranscriptKit"]),
    ]
)
