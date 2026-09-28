# MyFocus 开发命令
#
# 说明：系统 xcode-select 当前指向 Command Line Tools，但本机装有完整 Xcode 27。
# CLT 缺少 SwiftUI/SwiftData/swift-testing 的宏插件，因此所有命令统一用
# DEVELOPER_DIR 指向 Xcode 工具链（免 sudo 切换 xcode-select）。

export DEVELOPER_DIR = /Applications/Xcode.app/Contents/Developer

.PHONY: build release test run bench clean

build:
	swift build

release:
	swift build -c release

test:
	swift test

run:
	swift run MyFocus

bench:
	swift run -c release Bench

clean:
	swift package clean
