#import <UIKit/UIKit.h>

@class PDFDocument;
@class PDFView;

NS_ASSUME_NONNULL_BEGIN

@interface FFPDFThumbnailGridController : UIViewController

- (instancetype)initWithDocument:(PDFDocument *)document pdfView:(PDFView *)pdfView;

@end

NS_ASSUME_NONNULL_END
