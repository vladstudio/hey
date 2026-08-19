// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hey",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../app-kit"),
    ],
    targets: [
        .executableTarget(
            name: "Hey",
            dependencies: [.product(name: "MacAppKit", package: "app-kit")],
            path: "app/Hey",
            exclude: ["Info.plist"]
        )
    ]
)