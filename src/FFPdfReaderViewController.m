#import "FFPdfReaderViewController.h"
#import "FFPDFThumbnailGridController.h"

#import <PDFKit/PDFKit.h>

@implementation FFPdfReaderViewController

- (void)showThumbnails
{
    PDFView *pdfView = [self valueForKey:@"pdfView"];
    PDFDocument *document = [self valueForKey:@"document"];
    if (![pdfView isKindOfClass:PDFView.class] || ![document isKindOfClass:PDFDocument.class]) return;

    FFPDFThumbnailGridController *panel =
        [[FFPDFThumbnailGridController alloc] initWithDocument:document pdfView:pdfView];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        nav.modalPresentationStyle = UIModalPresentationPopover;
        nav.preferredContentSize = CGSizeMake(560, 680);
        UIBarButtonItem *anchor = self.navigationItem.rightBarButtonItems.firstObject;
        if (anchor) nav.popoverPresentationController.barButtonItem = anchor;
        else {
            nav.popoverPresentationController.sourceView = self.view;
            nav.popoverPresentationController.sourceRect = CGRectMake(
                CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        }
    } else {
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            nav.sheetPresentationController.detents = @[
                UISheetPresentationControllerDetent.mediumDetent,
                UISheetPresentationControllerDetent.largeDetent,
            ];
            nav.sheetPresentationController.prefersGrabberVisible = YES;
            nav.sheetPresentationController.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
        }
    }
    [self presentViewController:nav animated:YES completion:nil];
}

@end
