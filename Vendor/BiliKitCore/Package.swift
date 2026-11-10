// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "BiliKitCore", platforms: [.macOS(.v15), .iOS(.v26)], products: ["BiliModels", "BiliNetworking", "BiliPlayback"].map { .library(name: $0, targets: [$0]) }, targets: [
    .target(name: "BiliModels"), .target(name: "BiliApplication", dependencies: ["BiliModels"]), .target(name: "BiliNetworking"), .target(name: "BiliPlayback", dependencies: ["BiliModels", "BiliApplication", "BiliNetworking"]), .testTarget(name: "BiliPlaybackTests", dependencies: ["BiliPlayback", "BiliModels", "BiliApplication", "BiliNetworking"], resources: [.copy("Fixtures")])
])
