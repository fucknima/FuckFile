# latest = use the SDK shipped with the installed Xcode (GitHub Actions
# macos runners only provide the Xcode SDK, not theos/sdks packages).
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FuckFile
APPEX_NAME = FuckFileShare

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
	src/FFImportService.m \
	src/FFSharedInboxService.m \
	src/MCMManager+ExtensionData.m \
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
	src/FFPathBreadcrumbView.m \
	src/FFFileMetadataService.m \
	src/FFFileInfoViewController.m \
	src/FFViewerPickerViewController.m

FuckFile_CFLAGS = -I$(PWD)/src -I$(PWD)/third_party/minizip -fobjc-arc \
	-Wno-unused-function -Wno-unused-variable -Wno-format \
	-Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers \
	-Wno-deprecated-declarations
FuckFile_CCFLAGS = $(FuckFile_CFLAGS) -Wno-implicit-function-declaration
FuckFile_OBJCFLAGS = $(FuckFile_CFLAGS)

FuckFile_FRAMEWORKS = UIKit Foundation CoreFoundation AVKit AVFoundation PDFKit QuickLook WebKit
FuckFile_LIBRARIES = z sqlite3
FuckFile_INFOPLIST = Info.plist

# LCSign-style share-sheet receiver. The extension persists the provider
# representation while its callback is alive; it never hands a temporary
# provider path to the main app.
FuckFileShare_FILES = ShareExtension/FFShareViewController.m
FuckFileShare_CFLAGS = -I$(PWD)/src -fobjc-arc -Wno-deprecated-declarations
FuckFileShare_OBJCFLAGS = $(FuckFileShare_CFLAGS)
FuckFileShare_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers
FuckFileShare_INFOPLIST = ShareExtension/Info.plist
FuckFileShare_INSTALL_PATH = /Applications/FuckFile.app/PlugIns

# The MCM identity bypass requires the host bundle identifier to be exactly
# this system identity. Do not change it: MobileContainerManager then trusts
# the caller and issues foreign-container sandbox extensions.
FuckFile_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/appex.mk

after-stage::
	@APP="$(THEOS_STAGING_DIR)/Applications/FuckFile.app"; \
	EXT="$$APP/PlugIns/FuckFileShare.appex"; \
	if [ -d "$$EXT" ]; then codesign --force -s - "$$EXT"; fi; \
	codesign --force -s - "$$APP"
	@echo "== ad-hoc re-signed FuckFile.app + nested share extension"
