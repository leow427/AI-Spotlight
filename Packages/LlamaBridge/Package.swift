// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "LlamaBridge",
  platforms: [
    .macOS(.v13),
  ],
  products: [
    .library(name: "LlamaBridge", targets: ["LlamaBridge"]),
  ],
  targets: [
    .binaryTarget(
      name: "LlamaFramework",
      url: "https://github.com/ggml-org/llama.cpp/releases/download/b5046/llama-b5046-xcframework.zip",
      checksum: "c19be78b5f00d8d29a25da41042cb7afa094cbf6280a225abe614b03b20029ab"
    ),
    .target(
      name: "LlamaBridge",
      dependencies: ["LlamaFramework"],
      publicHeadersPath: "include"
    ),
  ]
)
