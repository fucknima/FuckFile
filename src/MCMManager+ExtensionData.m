#import "MCMManager+ExtensionData.h"

@interface MCMManager (ExtensionDataPrivate)
- (nullable NSString *)activate:(uint64_t)containerClass
                      identifier:(NSString *)identifier
                           group:(BOOL)group
                           error:(NSString * _Nullable * _Nullable)error;
@end

@implementation MCMManager (ExtensionData)

- (NSString *)extensionContainerPathForIdentifier:(NSString *)identifier
                                             error:(NSString **)error
{
    // FilzaSlop / MobileContainerManager mapping: class 4 = Extension Data.
    return [self activate:4 identifier:identifier group:NO error:error];
}

@end
