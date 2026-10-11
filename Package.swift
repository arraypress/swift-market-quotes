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

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
