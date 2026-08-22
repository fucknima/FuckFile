#import "FFQuickLookViewController.h"

#import "FFLogger.h"

@interface FFQuickLookViewController () <QLPreviewControllerDataSource>
@property(nonatomic, copy) NSString *filePath;
@end

@implementation FFQuickLookViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    self = [super init];
    if (self) {
        _filePath = [path copy];
        // QLPreviewController renders its own title; keep it aligned.
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.dataSource = self;
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
