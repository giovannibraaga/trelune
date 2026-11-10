// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Trelune", platforms: [.macOS(.v14)], products: [.executable(name: "Trelune", targets: ["Trelune"])], targets: [.executableTarget(name: "Trelune"), .testTarget(name: "TreluneTests", dependencies: ["Trelune"])])
