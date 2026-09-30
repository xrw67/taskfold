# MyFocus 开发命令
#
# 说明：系统 xcode-select 当前指向 Command Line Tools，但本机装有完整 Xcode 27。
# CLT 缺少 SwiftUI/SwiftData/swift-testing 的宏插件，因此所有命令统一用
# DEVELOPER_DIR 指向 Xcode 工具链（免 sudo 切换 xcode-select）。
#
# 两套构建体系并存：
#   Swift Package（swift build/test/run）—— CLI 工作流，快速迭代
#   MyFocus.xcodeproj（xcodegen 生成）—— Xcode IDE、.app bundle、调试与分发

export DEVELOPER_DIR = /Applications/Xcode.app/Contents/Developer

.PHONY: build release test run bench clean project xbuild xtest xapp icon

# --- Swift Package 工作流 ---

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

# --- Xcode 工作流 ---

# 修改 project.yml 后重新生成 MyFocus.xcodeproj
project:
	xcodegen generate

# xcodebuild 构建 App scheme（含测试）
xbuild:
	xcodebuild -project MyFocus.xcodeproj -scheme MyFocus -derivedDataPath .build/xcode build

xtest:
	xcodebuild -project MyFocus.xcodeproj -scheme MyFocus -derivedDataPath .build/xcode test

# 启动 xcodebuild 产物 .app
xapp:
	open .build/xcode/Build/Products/Debug/MyFocus.app

# 重新生成应用图标（改 scripts/gen_icon.swift 后执行，随后 make xbuild）
icon:
	swift scripts/gen_icon.swift Sources/MyFocus/Resources/Assets.xcassets/AppIcon.appiconset
	rm -f Sources/MyFocus/Resources/Assets.xcassets/AppIcon.appiconset/preview_512.png
