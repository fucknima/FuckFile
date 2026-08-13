#import "FFPdfPreviewViewController.h"
#import "FFLogger.h"

#import <PDFKit/PDFKit.h>

@interface FFPdfPreviewViewController () <PDFViewDelegate>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) PDFView *pdfView;
@property(nonatomic, strong) PDFDocument *document;
@property(nonatomic, strong) UIButton *thumbnailsButton;
@end

@implementation FFPdfPreviewViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super init];
    if (self) {
        _filePath = path;
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.pdfView = [PDFView new];
    self.pdfView.translatesAutoresizingMaskIntoConstraints = NO;
    self.pdfView.autoScales = YES;
    self.pdfView.displayMode = kPDFDisplaySinglePageContinuous;
    self.pdfView.displayDirection = kPDFDisplayDirectionVertical;
    self.pdfView.delegate = self;
    [self.view addSubview:self.pdfView];
    [NSLayoutConstraint activateConstraints:@[
        [self.pdfView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.pdfView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.pdfView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.pdfView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    self.thumbnailsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.thumbnailsButton setTitle:@"缩略图" forState:UIControlStateNormal];
    [self.thumbnailsButton addTarget:self action:@selector(toggleThumbnails)
                    forControlEvents:UIControlEventTouchUpInside];
    self.thumbnailsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.thumbnailsButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.thumbnailsButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.thumbnailsButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];

    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemAction target:self action:@selector(share)];
    self.navigationItem.rightBarButtonItem = share;

    [self loadDocument];
}

- (void)loadDocument
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        PDFDocument *document = [[PDFDocument alloc] initWithURL:
            [NSURL fileURLWithPath:weakSelf.filePath]];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.document = document;
            if (document) {
                weakSelf.pdfView.document = document;
                FFLogTag(@"Preview", @"pdf opened path=%@ pages=%lu",
                         weakSelf.filePath, (unsigned long)document.pageCount);
            } else {
                [weakSelf showLoadFailure];
            }
        });
    });
}

- (void)toggleThumbnails
{
    if (!self.document) return;
    if (!self.pdfView.documentView) return;
    PDFThumbnailView *thumbnail = [PDFThumbnailView new];
    thumbnail.translatesAutoresizingMaskIntoConstraints = NO;
    thumbnail.pdfView = self.pdfView;
    thumbnail.thumbnailSize = CGSizeMake(72, 96);
    thumbnail.layoutMode = PDFThumbnailLayoutModeVertical;
    thumbnail.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.view addSubview:thumbnail];
    NSLayoutConstraint *leading = [thumbnail.leadingAnchor
        constraintEqualToAnchor:self.view.leadingAnchor constant:8];
    leading.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        leading,
        [thumbnail.widthAnchor constraintEqualToConstant:96],
        [thumbnail.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [thumbnail.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [self.pdfView.leadingAnchor constraintEqualToAnchor:thumbnail.trailingAnchor constant:8],
    ]];
    // Tap again (or anywhere on the thumbnail) removes it.
    UITapGestureRecognizer *dismiss = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissThumbnail:)];
    [thumbnail addGestureRecognizer:dismiss];
    thumbnail.userInteractionEnabled = YES;
    self.thumbnailsButton.hidden = YES;
}

- (void)dismissThumbnail:(UITapGestureRecognizer *)gesture
{
    [gesture.view removeFromSuperview];
    [self.pdfView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
    self.thumbnailsButton.hidden = NO;
}

- (void)share
{
    NSURL *url = [NSURL fileURLWithPath:self.filePath];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)showLoadFailure
{
    FFLogTag(@"Preview", @"pdf load FAIL path=%@", self.filePath);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开 PDF"
        message:@"文件损坏、加密或不可读。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
