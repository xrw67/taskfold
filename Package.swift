// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Taskfold",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TaskfoldKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            exclude: ["Info.plist"]  // xcodegen 生成，仅供 Xcode 工程使用
        ),
        .executableTarget(
            name: "Taskfold",
            dependencies: ["TaskfoldKit"],
            exclude: ["Info.plist"],  // 同上
            resources: [
                .process("Resources/Assets.xcassets"),
                .copy("Resources/Help.md"),  // 应用内帮助文档（帮助 → 使用帮助）
            ]
        ),
        .executableTarget(
            name: "Bench",
            dependencies: [
                "TaskfoldKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TaskfoldKitTests",
            dependencies: ["TaskfoldKit"]
        ),
    ]
)
