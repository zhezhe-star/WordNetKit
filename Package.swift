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
        .library(name: "WordNetKit", type: .dynamic, targets: ["WordNetKit"]),
        .library(name: "WordNetKitData", type: .static, targets: ["WordNetKitData"]),
    ],
    targets: [
        .target(
            name: "WordNetKit",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "WordNetKitData",
            resources: [.copy("Resources/wordnet.sqlite")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WordNetKitTests",
            dependencies: ["WordNetKit", "WordNetKitData"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
