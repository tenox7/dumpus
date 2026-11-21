// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dumpus",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CDumpus"),
        .executableTarget(
            name: "Dumpus",
            dependencies: ["CDumpus"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
    ]
)
