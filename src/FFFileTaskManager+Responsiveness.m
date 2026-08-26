#import "FFFileTaskManager.h"
#import <objc/runtime.h>

static const void *kFFHeavyNotifyPendingKey = &kFFHeavyNotifyPendingKey;

@interface FFFileTaskManager (FFResponsivenessPrivate)
- (void)notifyChange;
- (instancetype)ff_responsive_init;
- (void)ff_responsive_notifyChange;
@end

@implementation FFFileTaskManager (Responsiveness)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = self;
        Method initOriginal = class_getInstanceMethod(cls, @selector(init));
        Method initReplacement = class_getInstanceMethod(cls, @selector(ff_responsive_init));
        Method notifyOriginal = class_getInstanceMethod(cls, @selector(notifyChange));
        Method notifyReplacement = class_getInstanceMethod(cls, @selector(ff_responsive_notifyChange));
        if (initOriginal && initReplacement) method_exchangeImplementations(initOriginal, initReplacement);
        if (notifyOriginal && notifyReplacement) method_exchangeImplementations(notifyOriginal, notifyReplacement);
    });
}

- (instancetype)ff_responsive_init
{
    FFFileTaskManager *manager = [self ff_responsive_init];
    if (!manager) return nil;

    // Compression/large copies are throughput work, not interactive work. Give
    // them utility QoS so UIKit/main-thread input and animations win CPU time
    // under sustained zlib + disk load. The queue remains serial, preserving the
    // task ordering semantics of the original manager.
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    dispatch_queue_t utilityQueue = dispatch_queue_create("ff.tasks", attr);
    [manager setValue:utilityQueue forKey:@"workQueue"];
    return manager;
}

- (BOOL)ff_hasRunningCompressionOrExtraction
{
    for (FFFileTask *task in self.tasks) {
        if (task.state != FFFileTaskStateRunning) continue;
        if (task.kind == FFFileTaskKindCompress || task.kind == FFFileTaskKindExtract)
            return YES;
    }
    return NO;
}

- (void)ff_responsive_notifyChange
{
    // Keep state transitions (enqueue/start/finish/cancel) immediate when no
    // heavy archive task is active. Only coalesce the high-frequency progress
    // storm produced while compression/extraction is running.
    if (![self ff_hasRunningCompressionOrExtraction]) {
        [self ff_responsive_notifyChange];
        return;
    }

    @synchronized (self) {
        if ([objc_getAssociatedObject(self, kFFHeavyNotifyPendingKey) boolValue]) return;
        objc_setAssociatedObject(self, kFFHeavyNotifyPendingKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    __weak FFFileTaskManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            FFFileTaskManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            @synchronized (strongSelf) {
                objc_setAssociatedObject(strongSelf, kFFHeavyNotifyPendingKey, @NO,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            // Swizzled selector now points at the previous implementation. This
            // deliberately preserves the persistence category's notify chain.
            [strongSelf ff_responsive_notifyChange];
        });
}

@end
