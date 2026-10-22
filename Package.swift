// swift-tools-version:5.9
// Builds the Mac menu bar app. The iPhone app is the Xcode project from project.yml.
import PackageDescription

let package = Package(
    name: "Googly",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GooglyMac", targets: ["GooglyMac"]),
    ],
    targets: [
        .target(name: "GooglyShared", path: "Shared", exclude: ["Fonts"]),
        .executableTarget(
            name: "GooglyMac",
            dependencies: ["GooglyShared"],
            path: "Mac/Sources/GooglyMac"
        ),
        .testTarget(name: "GooglyMacTests", dependencies: ["GooglyMac", "GooglyShared"], path: "Tests/GooglyMacTests"),
        .testTarget(name: "GooglySharedTests", dependencies: ["GooglyShared"], path: "Tests/GooglySharedTests"),
    ]
)
