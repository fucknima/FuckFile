#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class FFEntry;

/// Central visual language for browser file/folder icons.
///
/// The provider deliberately returns full-colour, always-original images on a
/// 48pt canvas. Browser list/grid configurations already cap images at 40/48pt,
/// so these icons occupy the same optical box as real app thumbnails instead of
/// inheriting the much smaller optical bounds of arbitrary SF Symbols.
@interface FFFileIconProvider : NSObject

+ (UIImage *)iconForEntry:(FFEntry *)entry;

@end

NS_ASSUME_NONNULL_END
