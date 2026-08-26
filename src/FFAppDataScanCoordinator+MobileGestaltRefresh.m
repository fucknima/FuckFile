#import "FFAppDataScanCoordinator.h"
#import "FFStorageEnvironment.h"
#import "MCMManager.h"
#import "FFLogger.h"
#import <objc/runtime.h>

@interface MCMManager (FFMobileGestaltRefreshPrivate)
- (void)runMobileGestaltProbe:(NSString *)root;
@end

@interface FFAppDataScanCoordinator (MobileGestaltRefresh)
- (void)ff_mobileGestalt_bootstrapWithCompletion:(void (^)(BOOL ready, NSString *failureReason))completion;
@end

@implementation FFAppDataScanCoordinator (MobileGestaltRefresh)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(bootstrapWithCompletion:));
        Method replacement = class_getInstanceMethod(self, @selector(ff_mobileGestalt_bootstrapWithCompletion:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)ff_mobileGestalt_bootstrapWithCompletion:(void (^)(BOOL, NSString *))completion
{
    [self ff_mobileGestalt_bootstrapWithCompletion:^(BOOL ready, NSString *failureReason) {
        if (!ready) {
            if (completion) completion(NO, failureReason);
            return;
        }

        // The normal cold-start bootstrap intentionally avoids a full AppData
        // scan when the registry is already populated. MobileGestalt is not a
        // registry-backed AppData entry, however: its class-12 scoped MCM lease
        // must be reacquired by every process. Refresh it once here before the
        // system-access state becomes usable to callers.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [MCMManager.sharedManager runMobileGestaltProbe:FFStorageRootPath()];
            FFLogTag(@"SystemAccess", @"cold-start MobileGestalt lease refresh finished");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES, failureReason);
            });
        });
    }];
}

@end
