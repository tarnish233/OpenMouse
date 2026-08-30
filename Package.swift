// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenMouse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenMouse", targets: ["OpenMouse"])
    ],
    targets: [
        .executableTarget(
            name: "OpenMouse",
            path: "Sources/OpenMouse",
            swiftSettings: [
                // The event-tap layer is inherently callback/C-pointer based and runs
                // on the main run loop; Swift 5 isolation keeps that code readable.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
