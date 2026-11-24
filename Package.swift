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
        .target(name: "InboxUI", dependencies: ["InboxCore"]),
        .executableTarget(name: "InboxBadge", dependencies: ["InboxCore", "InboxUI"]),
        .executableTarget(name: "InboxPreview", dependencies: ["InboxCore", "InboxUI"]),
        .testTarget(name: "InboxCoreTests", dependencies: ["InboxCore"]),
    ],
    swiftLanguageModes: [.v5]
)
