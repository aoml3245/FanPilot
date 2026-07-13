// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanPilot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FanPilot", targets: ["FanPilot"]),
        .executable(name: "FanPilotHelper", targets: ["FanPilotHelper"])
    ],
    targets: [
        .executableTarget(
            name: "FanPilot",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "FanPilotHelper",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
