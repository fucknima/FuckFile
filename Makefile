# Swift 重写分支（swift-fuckfile）：App 只编译 Sources/*.swift。
# 原 Objective-C 实现保留在 src/ 作为参考，等重写达到功能对齐后再删除；
# 这里不再编译它，也不再有 runtime/libarchive 的构建期依赖。
TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FuckFile

FuckFile_FILES = $(shell find Sources -name '*.swift' | sort)
FuckFile_FRAMEWORKS = UIKit SwiftUI Foundation QuickLook PDFKit AVKit
FuckFile_INFOPLIST = Info.plist
FuckFile_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	@APP="$(THEOS_STAGING_DIR)/Applications/FuckFile.app"; \
	codesign --force -s - --entitlements FuckFile.entitlements "$$APP"; \
	echo "== ad-hoc re-signed FuckFile.app (Swift rewrite)"
