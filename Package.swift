// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MyFocus",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "MyFocusKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            exclude: ["Info.plist"]  // xcodegen 生成，仅供 Xcode 工程使用
        ),
        .executableTarget(
            name: "MyFocus",
            dependencies: ["MyFocusKit"],
            exclude: ["Info.plist"],  // 同上
            resources: [.process("Resources/Assets.xcassets")]
        ),
        .executableTarget(
            name: "Bench",
            dependencies: [
                "MyFocusKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "MyFocusKitTests",
            dependencies: ["MyFocusKit"]
        ),
    ]
)
