// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MooOve",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "MooOve", targets: ["MooOve"])
    ],
    targets: [
        .executableTarget(
            name: "MooOve",
            path: "Sources/MooOve"
        )
    ]
)
