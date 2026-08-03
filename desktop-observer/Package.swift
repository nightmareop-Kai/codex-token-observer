// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexTokenObserver",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "CodexTokenObserver", path: "Sources/CodexTokenObserver")]
)
