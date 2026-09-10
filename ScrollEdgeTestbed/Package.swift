// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScrollEdgeTestbed",
    platforms: [.macOS("26.1")],
    targets: [
        .executableTarget(
            name: "ScrollEdgeTestbed",
            path: "Sources/ScrollEdgeTestbed"
        ),
        .executableTarget(
            name: "SwiftUIEdgeTestbed",
            path: "Sources/SwiftUIEdgeTestbed"
        )
    ]
)