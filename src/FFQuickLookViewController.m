#import "FFQuickLookViewController.h"

#import "FFLogger.h"

#import <UIKit/UIKit.h>

@interface FFQuickLookViewController () <QLPreviewControllerDataSource>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic) BOOL needsForegroundRefresh;
@property(nonatomic) unsigned long long backgroundFileSize;
@property(nonatomic, strong, nullable) NSDate *backgroundModificationDate;
@end

@implementation FFQuickLookViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory)
        return nil;
    self = [super init];
    if (self) {
        _filePath = [path copy];
        self.hidesBottomBarWhenPushed = YES;
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.dataSource = self;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(applicationDidEnterBackground:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(applicationDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (self.dataSource != self) self.dataSource = self;
    if (self.needsForegroundRefresh &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        [self recoverPreviewIfVisible];
    }
}

- (void)applicationDidEnterBackground:(__unused NSNotification *)note
{
    self.needsForegroundRefresh = YES;
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:self.filePath error:nil];
    self.backgroundFileSize = [attributes[NSFileSize] unsignedLongLongValue];
    self.backgroundModificationDate = [attributes[NSFileModificationDate]
        isKindOfClass:NSDate.class] ? attributes[NSFileModificationDate] : nil;
    FFLogTag(@"QuickLook", @"background path=%@ visible=%d",
        self.filePath, self.viewIfLoaded.window != nil);
}

- (void)applicationDidBecomeActive:(__unused NSNotification *)note
{
    if (!self.needsForegroundRefresh) return;
    [self recoverPreviewIfVisible];
}

- (void)recoverPreviewIfVisible
{
    if (!self.isViewLoaded || !self.view.window ||
        (self.navigationController && self.navigationController.topViewController != self))
        return;

    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:self.filePath isDirectory:&directory] || directory) {
        FFLogTag(@"QuickLook", @"foreground file missing path=%@", self.filePath);
        self.needsForegroundRefresh = NO;
        return;
    }

    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:self.filePath error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    NSDate *modified = [attributes[NSFileModificationDate]
        isKindOfClass:NSDate.class] ? attributes[NSFileModificationDate] : nil;
    BOOL changed = size != self.backgroundFileSize ||
        ((self.backgroundModificationDate == nil) != (modified == nil)) ||
        (self.backgroundModificationDate && modified &&
         ![self.backgroundModificationDate isEqualToDate:modified]);

    self.needsForegroundRefresh = NO;
    self.dataSource = self;

    // Preserve-first policy: QLPreviewController exposes no public callback
    // telling us that its renderer process died. Refreshing unconditionally on
    // every foreground transition visibly resets the document and can discard
    // internal reading state. Therefore an unchanged file is left completely
    // untouched. A changed source is the only reliable signal that requires a
    // data/preview refresh; manual Quick Look remains available as fallback if
    // iOS ever reclaims the private preview renderer without telling us.
    if (!changed) {
        FFLogTag(@"QuickLook", @"foreground preserved unchanged preview path=%@", self.filePath);
        return;
    }

    [self reloadData];
    [self refreshCurrentPreviewItem];
    FFLogTag(@"QuickLook", @"foreground refreshed changed file path=%@", self.filePath);
}

#pragma mark - QLPreviewControllerDataSource

- (NSInteger)numberOfPreviewItemsInPreviewController:(__unused QLPreviewController *)controller
{
    return 1;
}

- (id<QLPreviewItem>)previewController:(__unused QLPreviewController *)controller
                    previewItemAtIndex:(__unused NSInteger)index
{
    return (id<QLPreviewItem>)[NSURL fileURLWithPath:self.filePath];
}

@end
