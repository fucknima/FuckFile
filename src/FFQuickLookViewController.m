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
        // Document previews own the full content area; the root app tab bar
        // otherwise floats over Quick Look's preview surface.
        self.hidesBottomBarWhenPushed = YES;
        // QLPreviewController renders its own title; keep it aligned.
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
        (self.backgroundModificationDate && modified &&
         ![self.backgroundModificationDate isEqualToDate:modified]);

    self.needsForegroundRefresh = NO;
    self.dataSource = self;
    if (changed) {
        [self reloadData];
        FFLogTag(@"QuickLook", @"foreground reload changed file path=%@", self.filePath);
    }

    [self refreshCurrentPreviewItem];
    FFLogTag(@"QuickLook", @"foreground refresh path=%@ changed=%d", self.filePath, changed);
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
