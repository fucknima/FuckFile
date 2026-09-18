# Swift 重写分支（swift-fuckfile）：App 编译 Sources/*.swift + 少量 C 依赖
# （minizip 只用于 zip 读取）。原 Objective-C 实现保留在 src/ 作为参考，
# 不参与编译。
TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FuckFile

FuckFile_FILES = \
	$(shell find Sources -name '*.swift' | sort) \
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

include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	@APP="$(THEOS_STAGING_DIR)/Applications/FuckFile.app"; \
	codesign --force -s - --entitlements FuckFile.entitlements "$$APP"; \
	echo "== ad-hoc re-signed FuckFile.app (Swift rewrite)"
