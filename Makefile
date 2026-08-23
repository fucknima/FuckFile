# latest = use the SDK shipped with the installed Xcode (GitHub Actions
# macos runners only provide the Xcode SDK, not theos/sdks packages).
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FuckFile

FuckFile_FILES = \
	src/main.m \
	src/FFAppDelegate.m \
	src/FFLogger.m \
	src/FFHomeViewController.m \
	src/FFBrowserViewController.m \
	src/FFLogViewController.m \
	src/FFSettingsViewController.m \
	src/FFCopyEngine.m \
	src/FFPathPolicy.m \
	src/FFFileOperationService.m \
	src/FFAppNames.m \
	src/FFZipExtract.m \
	src/FFZipCreate.m \
	src/FFTextEditorViewController.m \
	src/FFPlistEditorViewController.m \
	src/FFPdfPreviewViewController.m \
	src/FFPreviewRouter.m \
	src/FFThumbnailService.m \
	src/FFFileTask.m \
	src/FFFileTaskManager.m \
	src/FFTasksViewController.m \
	src/FFSearchService.m \
	src/FFSearchViewController.m \
	src/FFBookmarksService.m \
	src/FFBookmarksViewController.m \
	src/MCMBridge.m \
	src/MCMManager.m \
	src/FFLSDiscovery.m \
	third_party/minizip/unzip.c \
	third_party/minizip/ioapi.c \
	src/FFViewerRegistry.m \
	src/FFFileAssociationService.m \
	src/FFQuickLookViewController.m \
	src/FFWebViewerViewController.m \
	src/FFHexEditorViewController.m \
	src/FFSQLiteService.m \
	src/FFSQLiteBrowserViewController.m \
	src/FFArchiveService.m \
	src/FFArchiveBrowserViewController.m \
	src/FFIPaInstallerViewController.m \
	src/FFSupportedViewersViewController.m \
	src/FFFileAssociationsViewController.m \
	src/FFImportService.m

FuckFile_CFLAGS = -I$(PWD)/src -I$(PWD)/third_party/minizip -fobjc-arc \
	-Wno-unused-function -Wno-unused-variable -Wno-format \
	-Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers \
	-Wno-deprecated-declarations
FuckFile_CCFLAGS = $(FuckFile_CFLAGS) -Wno-implicit-function-declaration
FuckFile_OBJCFLAGS = $(FuckFile_CFLAGS)

FuckFile_FRAMEWORKS = UIKit Foundation CoreFoundation AVKit AVFoundation PDFKit QuickLook WebKit
FuckFile_LIBRARIES = z sqlite3

FuckFile_INFOPLIST = Info.plist

# The MCM identity bypass requires the host bundle identifier to be exactly
# this system identity. Do not change it: MobileContainerManager then trusts
# the caller and issues foreign-container sandbox extensions.
FuckFile_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	@codesign --force -s - --preserve-metadata=identifier,entitlements $(THEOS_STAGING_DIR)/Applications/FuckFile.app 2>/dev/null || true
	@echo "== ad-hoc re-signed .app at $(THEOS_STAGING_DIR)/Applications/FuckFile.app"

# ---- Share Extension（theos appex.mk 官方路径，自动 -e _NSExtensionMain）----
APPEX_NAME = FFShareExtension
FFShareExtension_CFLAGS = -I$(PWD)/ShareExtension -fobjc-arc \
	-Wno-unused-function -Wno-unused-variable -Wno-format \
	-Wno-incompatible-pointer-types -Wno-deprecated-declarations
FFShareExtension_CCFLAGS = $(FFShareExtension_CFLAGS)
FFShareExtension_OBJCFLAGS = $(FFShareExtension_CFLAGS)
FFShareExtension_FILES = ShareExtension/FFShareViewController.m
FFShareExtension_FRAMEWORKS = UIKit Foundation Social UniformTypeIdentifiers
FFShareExtension_INSTALL_PATH = /Applications
# Info.plist 由构建目录中的资源自动带入（bundle.mk 规则）。
FFShareExtension_RESOURCE_DIRS = ShareExtensionResources

include $(THEOS_MAKE_PATH)/appex.mk

# 把 appex 嵌入主 app 的 PlugIns/（CI 在 Package 段 rsync）。
after-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/Applications/FuckFile.app/PlugIns
	@rm -rf $(THEOS_STAGING_DIR)/Applications/FuckFile.app/PlugIns/FFShareExtension.appex
	@rsync -a $(THEOS_STAGING_DIR)/Applications/FFShareExtension.appex/ \
		$(THEOS_STAGING_DIR)/Applications/FuckFile.app/PlugIns/FFShareExtension.appex/ 2>/dev/null || true
	@echo "== share extension staged"
