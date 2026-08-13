// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CalendarBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CalendarBar",
            path: "Sources/CalendarBar"
        )
    ]
)
