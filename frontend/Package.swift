// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Mini",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(name: "Mini", dependencies: ["CShm"]),
    .target(name: "CShm"),
    .testTarget(name: "MiniTests", dependencies: ["Mini"]),
  ]
)
