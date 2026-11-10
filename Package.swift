// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacFaceID",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "FaceIDCore",
            targets: ["FaceIDCore"]
        ),
        .executable(
            name: "MacFaceID",
            targets: ["MacFaceIDApp"]
        ),
        .executable(
            name: "faceid-cli",
            targets: ["FaceIDCLI"]
        )
    ],
    targets: [
        .target(
            name: "FaceIDCore",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreML"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "MacFaceIDApp",
            dependencies: ["FaceIDCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .executableTarget(
            name: "FaceIDCLI",
            dependencies: ["FaceIDCore"]
        ),
        .testTarget(
            name: "FaceIDCoreTests",
            dependencies: ["FaceIDCore"]
        )
    ]
)

