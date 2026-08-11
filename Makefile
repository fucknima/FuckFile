# latest = use the SDK shipped with the installed Xcode (GitHub Actions
# macos runners only provide the Xcode SDK, not theos/sdks packages).
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FuckFile

FuckFile_FILES = \
	src/main.m \
	src/FFAppDelegate.m \
	src/FFBrowserViewController.m \
	src/FFCopyEngine.m \
	src/MCMBridge.m \
	src/MCMManager.m \
	src/BadQueryProbe.m \
	src/BadQuery.c

FuckFile_CFLAGS = -I$(PWD)/src -fobjc-arc \
	-Wno-unused-function -Wno-unused-variable -Wno-format \
	-Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers \
	-Wno-deprecated-declarations
FuckFile_CCFLAGS = $(FuckFile_CFLAGS)
FuckFile_OBJCFLAGS = $(FuckFile_CFLAGS)

FuckFile_FRAMEWORKS = UIKit Foundation CoreFoundation
FuckFile_LIBRARIES = z

FuckFile_INFOPLIST = Info.plist

# The MCM identity bypass requires the host bundle identifier to be exactly
# this system identity. Do not change it: MobileContainerManager then trusts
# the caller and issues foreign-container sandbox extensions.
FuckFile_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	@codesign --force -s - --preserve-metadata=identifier,entitlements $(THEOS_STAGING_DIR)/Applications/FuckFile.app 2>/dev/null || true
	@echo "== ad-hoc re-signed .app at $(THEOS_STAGING_DIR)/Applications/FuckFile.app"
