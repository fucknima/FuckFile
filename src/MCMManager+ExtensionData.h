#import "MCMManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface MCMManager (ExtensionData)
// MobileContainerManager class 4 = Extension Data (PluginKitPlugin container).
// Used as a signer-independent bridge from FuckFileShare.appex when an
// App Group entitlement is unavailable after re-signing.
- (nullable NSString *)extensionContainerPathForIdentifier:(NSString *)identifier
                                                     error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
