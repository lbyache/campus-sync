// swift-tools-version: 6.1
import PackageDescription

// Sin dependencias externas: solo Foundation, Security y CryptoKit (ADR 0001).
let package = Package(
    name: "campus-sync",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "campus-sync", targets: ["campus-sync"]),
        .library(name: "CampusSyncCore", targets: ["CampusSyncCore"]),
    ],
    targets: [
        .target(name: "CampusSyncCore"),
        .executableTarget(name: "campus-sync", dependencies: ["CampusSyncCore"]),
        .testTarget(
            name: "CampusSyncCoreTests",
            dependencies: ["CampusSyncCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
