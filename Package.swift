// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "BiliGlass", platforms: [.macOS(.v15)], products: [.executable(name: "BiliGlass", targets: ["BiliGlass"])], dependencies: [.package(path: "Vendor/BiliKitCore"), .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")], targets: [
    .executableTarget(name: "BiliGlass", dependencies: [.product(name: "Sparkle", package: "Sparkle"), .product(name: "BiliModels", package: "BiliKitCore"), .product(name: "BiliNetworking", package: "BiliKitCore"), .product(name: "BiliPlayback", package: "BiliKitCore")], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "BiliGlassTests", dependencies: ["BiliGlass"])
])
