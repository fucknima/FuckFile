#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class FFEntry;

// Metadata for one registered viewer (settings pages, open-with menus).
@interface FFViewerInfo : NSObject
@property(nonatomic, copy, readonly) NSString *viewerID;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly) NSString *iconName;   // SF Symbol
@property(nonatomic, copy, readonly) NSString *summary;    // one-line capability note
@end

// Single source of truth for viewers: identity, display metadata,
// availability and the actual open implementation. FFPreviewRouter maps a
// file to a viewer ID via FFFileAssociationService and hands it here —
// nothing else pushes viewer view controllers.
@interface FFViewerRegistry : NSObject

+ (instancetype)sharedRegistry;

// All viewers in fixed presentation order.
- (NSArray<FFViewerInfo *> *)allViewers;

- (nullable FFViewerInfo *)viewerForID:(NSString *)viewerID;

// Whether the viewer can handle this path right now; on NO *reason
// explains why (shown verbatim in UI). path may be nil for a plain
// availability check.
- (BOOL)viewerAvailable:(NSString *)viewerID
                   path:(nullable NSString *)path
                 reason:(NSString * _Nullable * _Nullable)reason;

// Opens the path in the given viewer and pushes onto nav. Returns YES
// when pushed; NO means "unavailable" — callers should fall back.
- (BOOL)openPath:(NSString *)path
           title:(nullable NSString *)title
        viewerID:(NSString *)viewerID
navigationController:(UINavigationController *)nav;

@end

NS_ASSUME_NONNULL_END
