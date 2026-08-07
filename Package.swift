// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WordNetKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .macCatalyst(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "WordNetKit", targets: ["WordNetKit"])
    ],
    targets: [
        .target(
            name: "WordNetKit",
            resources: [.copy("Resources/wordnet.sqlite")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "WordNetKitTests",
            dependencies: ["WordNetKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
