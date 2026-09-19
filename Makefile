# Swift 重写分支（swift-fuckfile）：主 App 编译 Sources/*.swift（排除分享扩展）
# + minizip C 依赖；分享扩展是独立的 Swift appex。
TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FuckFile
APPEX_NAME = FuckFileShare

FuckFile_FILES = \
	$(shell find Sources -name '*.swift' ! -path 'Sources/ShareExtension/*' | sort) \
	third_party/minizip/unzip.c \
	third_party/minizip/ioapi.c
FuckFile_CFLAGS = -I$(PWD)/third_party/minizip
FuckFile_CCFLAGS = $(FuckFile_CFLAGS)
FuckFile_OBJCFLAGS = $(FuckFile_CFLAGS)
FuckFile_SWIFT_BRIDGING_HEADER = $(PWD)/Sources/FuckFile-Bridging-Header.h
FuckFile_FRAMEWORKS = UIKit SwiftUI Foundation QuickLook PDFKit AVKit
FuckFile_LIBRARIES = z sqlite3 compression
FuckFile_INFOPLIST = Info.plist
FuckFile_INSTALL_PATH = /Applications

# 分享扩展：入口 + 回环桥 + 收件箱/导入所需的 Core 文件。
FuckFileShare_FILES = \
	Sources/ShareExtension/ShareViewController.swift \
	Sources/Core/ShareBridge.swift \
	Sources/Core/ShareInboxService.swift \
	Sources/Core/ImportService.swift \
	Sources/Core/StorageEnvironment.swift \
	Sources/Core/AppLog.swift
FuckFileShare_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers
FuckFileShare_INFOPLIST = ShareExtension/Info.plist
FuckFileShare_INSTALL_PATH = /Applications/FuckFile.app/PlugIns

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/appex.mk

after-stage::
	@APP="$(THEOS_STAGING_DIR)/Applications/FuckFile.app"; \
	EXT="$$APP/PlugIns/FuckFileShare.appex"; \
	if [ -d "$$EXT" ]; then codesign --force -s - --entitlements ShareExtension/FuckFileShare.entitlements "$$EXT"; fi; \
	codesign --force -s - --entitlements FuckFile.entitlements "$$APP"; \
	echo "== ad-hoc re-signed FuckFile.app + nested share extension (Swift rewrite)"
