// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MarketQuotes",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "MarketQuotes", targets: ["MarketQuotes"]),
    ],
    targets: [
        .target(name: "MarketQuotes"),
        .testTarget(
            name: "MarketQuotesTests",
            dependencies: ["MarketQuotes"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
