// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "BiliGlass", platforms: [.macOS(.v26)], products: [.executable(name: "BiliGlass", targets: ["BiliGlass"])], dependencies: [.package(path: "Vendor/BiliKitCore"), .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")], targets: [
    .executableTarget(name: "BiliGlass", dependencies: [.product(name: "BiliModels", package: "BiliKitCore"), .product(name: "BiliNetworking", package: "BiliKitCore"), .product(name: "BiliPlayback", package: "BiliKitCore"), .product(name: "Sparkle", package: "Sparkle")], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "BiliGlassTests", dependencies: ["BiliGlass"])
])
