// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PasteBop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PasteBop", targets: ["PasteBop"]),
        .library(name: "PasteBopCore", targets: ["PasteBopCore"]),
    ],
    targets: [
        .target(
            name: "PasteBopCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PasteBop",
            dependencies: ["PasteBopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PasteBopCoreTests",
            dependencies: ["PasteBopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
