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
	src/FFViewerPickerViewController.m \
	src/FFContentProbe.m \
	src/FFTextCodec.m \
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

# Vendored Runestone 全量 Swift 源（同模块编译）。
FuckFile_FILES += $(shell find third_party/runestone/0.5.2 -name "*.swift" | sort)

FuckFile_CFLAGS = -I$(PWD)/src -I$(PWD)/third_party/minizip \
	-I$(PWD)/third_party/tree-sitter/include \
	-I$(PWD)/third_party/tree-sitter/src \
	-fobjc-arc \
	-Wno-unused-function -Wno-unused-variable -Wno-format \
	-Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers \
	-Wno-deprecated-declarations \
	-Wno-error=implicit-fallthrough -Wno-error=unused-but-set-variable \
	-Wno-error=sign-compare -Wno-error=constant-conversion \
	-Wno-error=array-bounds -Wno-error=uninitialized
FuckFile_CCFLAGS = $(FuckFile_CFLAGS) -Wno-implicit-function-declaration
FuckFile_OBJCFLAGS = $(FuckFile_CFLAGS)

# Swift（vendored Runestone + FFCodeEditorView.swift）：
# Bridging（FuckFile-Bridging-Header.h）导入 C 头（tree_sitter/api.h +
# grammars.h）；-I include 路径供 `#include <tree_sitter/api.h>` 解析。
# 注意：必须传绝对路径 —— theos 的 swiftc 调用目录不在项目根。
FuckFile_SWIFT_BRIDGING_HEADER = $(PWD)/FuckFile-Bridging-Header.h
FuckFile_SWIFTFLAGS = -I$(PWD)/third_party/tree-sitter/include

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
	codesign --force -s - "$$APP"; \
	echo "== ad-hoc re-signed FuckFile.app + nested share extension"

# 语法高亮 queries 与 theme 资源进入 App bundle（CI 的 actool 再合并 Assets.car）。
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
