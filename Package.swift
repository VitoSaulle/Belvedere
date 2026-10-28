// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Belvedere",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BelvedereCore", targets: ["BelvedereCore"]),
        .executable(name: "belvedere-hook", targets: ["belvedere-hook"]),
        .executable(name: "belvedere-statusline", targets: ["belvedere-statusline"]),
    ],
    targets: [
        .target(name: "BelvedereCore"),
        .executableTarget(name: "belvedere-hook", dependencies: ["BelvedereCore"]),
        .executableTarget(name: "belvedere-statusline", dependencies: ["BelvedereCore"]),
        .testTarget(
            name: "BelvedereCoreTests",
            dependencies: ["BelvedereCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
