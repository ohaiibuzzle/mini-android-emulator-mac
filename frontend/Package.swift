// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Mini",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.11.0"),
  ],
  targets: [
    .executableTarget(
      name: "Mini",
      dependencies: [
        "CShm",
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
      ],
      plugins: [.plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")]
    ),
    .target(name: "CShm"),
    .testTarget(name: "MiniTests", dependencies: ["Mini"]),
  ]
)
