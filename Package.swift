// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GalePlayer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GalePlayer", targets: ["GalePlayer"]),
        .library(name: "GaleCore", targets: ["GaleCore"]),
    ],
    targets: [
        // libmpv C 接口：通过 pkg-config 解析（brew install mpv）
        .systemLibrary(name: "CMPV", pkgConfig: "mpv", providers: [.brew(["mpv"])]),

        // 纯逻辑层：播放列表 / 关键帧，可单测
        .target(name: "GaleCore"),

        .executableTarget(
            name: "GalePlayer",
            dependencies: ["GaleCore", "CMPV"]
        ),

        .testTarget(name: "GaleCoreTests", dependencies: ["GaleCore"]),
    ]
)
