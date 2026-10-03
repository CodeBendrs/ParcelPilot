// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParcelPilotKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ParcelPilotKit", targets: ["ParcelPilotKit"]),
    ],
    targets: [
        .target(name: "ParcelPilotKit"),
        .testTarget(
            name: "ParcelPilotKitTests",
            dependencies: ["ParcelPilotKit"]
        ),
    ]
)
