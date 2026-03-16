// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalTalker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LocalTalker", targets: ["LocalTalker"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "COnnxRuntime",
            path: "Sources/COnnxRuntime",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../vendor/onnxruntime/include"),
            ]
        ),
        .executableTarget(
            name: "LocalTalker",
            dependencies: ["COnnxRuntime"],
            path: "Sources/LocalTalker",
            resources: [
                .copy("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "vendor/onnxruntime/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib",
                ]),
                .linkedLibrary("onnxruntime"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
