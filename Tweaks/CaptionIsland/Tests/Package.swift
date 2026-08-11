// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CaptionIslandParserTests",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "CaptionParserKit", targets: ["CaptionParserKit"]),
    ],
    targets: [
        .target(name: "CaptionParserKit"),
        .testTarget(
            name: "CaptionParserKitTests",
            dependencies: ["CaptionParserKit"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
