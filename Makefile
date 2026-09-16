# latest = use the SDK shipped with the installed Xcode (GitHub Actions
# macos runners only provide the Xcode SDK, not theos/sdks packages).
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FuckFile
APPEX_NAME = FuckFileShare

# Prepare cached browser runtimes while Make parses resources. Normal
# incremental builds reuse the generated assets and do not reinstall npm deps.
# Every runtime is fail-closed: a missing JS bundle must fail the build instead
# of producing an IPA whose viewer opens to a blank page.
DOCX_RUNTIME_READY := $(shell bash scripts/prepare_docx_runtime.sh >/dev/null 2>&1 && echo yes || echo no)
UNIVER_RUNTIME_READY := $(shell bash scripts/prepare_univer_runtime.sh >/dev/null 2>&1 && echo yes || echo no)
OFFICE_RUNTIME_READY := $(shell bash scripts/prepare_office_runtime.sh >/dev/null 2>&1 && echo yes || echo no)
ifeq ($(DOCX_RUNTIME_READY),no)
$(error Failed to prepare offline DOCX runtime; run scripts/prepare_docx_runtime.sh for details)
endif
ifeq ($(UNIVER_RUNTIME_READY),no)
$(error Failed to prepare offline Univer spreadsheet runtime; run scripts/prepare_univer_runtime.sh for details)
endif
ifeq ($(OFFICE_RUNTIME_READY),no)
$(error Failed to prepare offline Office document runtime; run scripts/prepare_office_runtime.sh for details)
endif

FuckFile_FILES = \
	src/main.m \
	src/FFAppDelegate.m \
	src/FFRootTabBarController.m \
	src/FFAppDelegate+ShareWakeDedup.m \
	src/FFStorageEnvironment.m \
	src/FFLogger.m \
	src/FFBrowserViewController.m \
	src/FFBrowserViewController+GridStability.m \
	src/FFBrowserViewController+StorageRoot.m \
	src/FFBrowserViewController+LocalSearchFix.m \
	src/FFBrowserViewController+IPAThumbnail.m \
	src/FFBrowserViewController+FileIcons.m \
	src/FFFileIconProvider.m \
	src/FFLogViewController.m \
	src/FFSettingsViewController.m \
	src/FFWebDAVServer.m \
	src/FFWebDAVSettingsViewController.m \
	src/FFCopyEngine.m \
	src/FFPathPolicy.m \
	src/FFFileOperationService.m \
	src/FFImportService.m \
	src/FFSharedInboxService.m \
	src/FFLocalShareBridgeServer.m \
	src/FFZipExtract.m \
	src/FFZipCreate.m \
	src/FFArchiveCreate.m \
	src/FFArchiveCreateOptionsViewController.m \
	src/FFTextEditorViewController.m \
	src/FFPlistDocument.m \
	src/FFPlistValueEditorViewController.m \
	src/FFPlistEditorViewController.m \
	src/FFPdfPreviewViewController.m \
	src/FFPdfReaderViewController.m \
	src/FFPDFThumbnailGridController.m \
	src/FFPreviewRouter.m \
	src/FFDocxViewerViewController.m \
	src/FFSpreadsheetViewController.m \
	src/FFOfficeDocumentViewController.m \
	src/FFViewerStateStore.m \
	src/FFThumbnailService.m \
	src/FFIPAMetadataService.m \
	src/FFFileTask.m \
	src/FFFileTaskManager.m \
	src/FFFileTaskManager+Persistence.m \
	src/FFFileTaskManager+Responsiveness.m \
	src/FFTasksViewController.m \
	src/FFSearchService.m \
	src/FFBookmarksService.m \
	src/FFBookmarksViewController.m \
	third_party/minizip/unzip.c \
	third_party/minizip/ioapi.c \
	src/FFViewerRegistry.m \
	src/FFFileAssociationService.m \
	src/FFQuickLookViewController.m \
	src/FFWebViewerViewController.m \
	src/FFHexEditorViewController.m \
	src/FFMachOInspectorViewController.m \
	src/FFSQLiteService.m \
	src/FFSQLiteBrowserViewController.m \
	src/FFArchiveService.m \
	src/FFLibArchiveBackend.m \
	src/FFArchiveBrowserViewController.m \
	src/FFArchiveBrowserViewController+Encrypted.m \
	src/FFSupportedViewersViewController.m \
	src/FFFileAssociationsViewController.m \
	src/FFPathBreadcrumbView.m \
	src/FFFileMetadataService.m \
	src/FFFileInfoViewController.m \
	src/FFViewerPickerViewController.m \
	src/FFContentProbe.m \
	src/FFTextCodec.m \
	src/FFSearchSession.m \
	src/FFCodeEditorView.swift \
	third_party/tree-sitter/wasm_stub.c \
	third_party/tree-sitter/src/alloc.c \
	third_party/tree-sitter/src/get_changed_ranges.c \
	third_party/tree-sitter/src/language.c \
	third_party/tree-sitter/src/lexer.c \
	third_party/tree-sitter/src/node.c \
	third_party/tree-sitter/src/parser.c \
	third_party/tree-sitter/src/query.c \
	third_party/tree-sitter/src/stack.c \
	third_party/tree-sitter/src/subtree.c \
	third_party/tree-sitter/src/tree.c \
	third_party/tree-sitter/src/tree_cursor.c \
	third_party/tree-sitter-languages/c/src/parser.c \
	third_party/tree-sitter-languages/cpp/src/parser.c \
	third_party/tree-sitter-languages/cpp/src/scanner.c \
	third_party/tree-sitter-languages/objc/src/parser.c \
	third_party/tree-sitter-languages/swift/src/parser.c \
	third_party/tree-sitter-languages/swift/src/scanner.c \
	third_party/tree-sitter-languages/python/src/parser.c \
	third_party/tree-sitter-languages/python/src/scanner.c \
	third_party/tree-sitter-languages/javascript/src/parser.c \
	third_party/tree-sitter-languages/javascript/src/scanner.c \
	third_party/tree-sitter-languages/typescript/src/parser.c \
	third_party/tree-sitter-languages/typescript/src/scanner.c \
	third_party/tree-sitter-languages/typescript/tsx/src/parser.c \
	third_party/tree-sitter-languages/typescript/tsx/src/scanner.c \
	third_party/tree-sitter-languages/json/src/parser.c \
	third_party/tree-sitter-languages/html/src/parser.c \
	third_party/tree-sitter-languages/html/src/scanner.c \
	third_party/tree-sitter-languages/css/src/parser.c \
	third_party/tree-sitter-languages/css/src/scanner.c \
	third_party/tree-sitter-languages/bash/src/parser.c \
	third_party/tree-sitter-languages/bash/src/scanner.c \
	third_party/tree-sitter-languages/yaml/src/parser.c \
	third_party/tree-sitter-languages/yaml/src/scanner.c \
	third_party/tree-sitter-languages/xml/src/parser.c \
	third_party/tree-sitter-languages/xml/src/scanner.c \
	third_party/tree-sitter-languages/markdown/src/parser.c \
	third_party/tree-sitter-languages/markdown/src/scanner.c \
	third_party/tree-sitter-languages/markdown_inline/src/parser.c \
	third_party/tree-sitter-languages/markdown_inline/src/scanner.c \
	third_party/tree-sitter-languages/sql/src/parser.c \
	third_party/tree-sitter-languages/sql/src/scanner.c

FuckFile_FILES += $(shell find third_party/runestone/0.5.2 -name "*.swift" | sort)
FuckFile_RESOURCE_DIRS = .docx-runtime/DocxAssets .univer-runtime/bundle .office-runtime/bundle

# Keep third-party/noisy warnings scoped down, but do not globally suppress
# diagnostics that can hide ABI, bounds, initialization, or format bugs.
# Existing UIKit/Objective-C APIs intentionally use nil in several optional
# positions, so keep nullability diagnostics visible without blocking packaging.
FuckFile_CFLAGS = -I$(PWD)/src -I$(PWD)/third_party/minizip \
	-I$(PWD)/third_party/tree-sitter/include \
	-I$(PWD)/third_party/tree-sitter/src \
	-fobjc-arc \
	-Wno-unused-function -Wno-unused-variable \
	-Wno-deprecated-declarations \
	-Wno-error=nonnull \
	-Wno-error=implicit-fallthrough -Wno-error=unused-but-set-variable \
	-Wno-error=sign-compare -Wno-error=constant-conversion
FuckFile_CCFLAGS = $(FuckFile_CFLAGS)
FuckFile_OBJCFLAGS = $(FuckFile_CFLAGS)

FuckFile_SWIFT_BRIDGING_HEADER = $(PWD)/FuckFile-Bridging-Header.h
FuckFile_SWIFTFLAGS = -I$(PWD)/third_party/tree-sitter/include

FuckFile_FRAMEWORKS = UIKit Foundation CoreFoundation AVKit AVFoundation PDFKit QuickLook WebKit UniformTypeIdentifiers PhotosUI
FuckFile_LIBRARIES = z sqlite3
ifneq ($(strip $(FF_LIBARCHIVE_A)),)
FuckFile_CFLAGS += -DFF_BUNDLED_LIBARCHIVE=1
FuckFile_CCFLAGS += -DFF_BUNDLED_LIBARCHIVE=1
FuckFile_OBJCFLAGS += -DFF_BUNDLED_LIBARCHIVE=1
FuckFile_LDFLAGS += $(FF_LIBARCHIVE_A)
FuckFile_LIBRARIES += bz2 iconv xml2
endif
FuckFile_INFOPLIST = Info.plist

FuckFileShare_FILES = \
	ShareExtension/FFShareViewController.m \
	src/FFLocalShareBridgeClient.m
FuckFileShare_CFLAGS = -I$(PWD)/src -fobjc-arc -Wno-deprecated-declarations -Wno-error=nonnull
FuckFileShare_OBJCFLAGS = $(FuckFileShare_CFLAGS)
FuckFileShare_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers
FuckFileShare_INFOPLIST = ShareExtension/Info.plist
FuckFileShare_INSTALL_PATH = /Applications/FuckFile.app/PlugIns

FuckFile_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/appex.mk

after-stage::
	@APP="$(THEOS_STAGING_DIR)/Applications/FuckFile.app"; \
	EXT="$$APP/PlugIns/FuckFileShare.appex"; \
	if [ -d "$$EXT" ]; then codesign --force -s - --entitlements ShareExtension/FuckFileShare.entitlements "$$EXT"; fi; \
	codesign --force -s - --entitlements FuckFile.entitlements "$$APP"; \
	echo "== ad-hoc re-signed FuckFile.app + nested share extension with App Group entitlements"

after-stage::
	@APP="$(THEOS_STAGING_DIR)/Applications/FuckFile.app"; \
	mkdir -p "$$APP/Languages"; \
	for d in c cpp objc swift python javascript typescript tsx json html css bash yaml xml markdown sql; do \
		if [ -f "third_party/tree-sitter-languages/$$d/queries/highlights.scm" ]; then \
			mkdir -p "$$APP/Languages/$$d"; \
			cp "third_party/tree-sitter-languages/$$d/queries/highlights.scm" "$$APP/Languages/$$d/highlights.scm"; \
		elif [ -f "third_party/tree-sitter-languages/typescript/$$d/queries/highlights.scm" ]; then \
			mkdir -p "$$APP/Languages/$$d"; \
			cp "third_party/tree-sitter-languages/typescript/$$d/queries/highlights.scm" "$$APP/Languages/$$d/highlights.scm"; \
		fi; \
	done; \
	cp third_party/runestone/0.5.2/Theme.xcassets "$$APP/RunestoneTheme.xcassets" 2>/dev/null; \
	echo "== bundled editor language resources"
