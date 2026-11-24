// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InboxBadge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InboxCore", targets: ["InboxCore"]),
    ],
    targets: [
        .target(name: "InboxCore"),
    ]
)
