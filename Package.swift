// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dumpus",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CDumpus"),
        .executableTarget(
            name: "DumpusHelper",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
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
