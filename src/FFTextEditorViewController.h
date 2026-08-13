#import <UIKit/UIKit.h>

// Plain-text file editor. Edits a file in place; when the sandbox denies
// the write (escaped read-only paths) it offers to save a copy into the
// app's own Documents folder instead.
@interface FFTextEditorViewController : UIViewController

- (instancetype)initWithPath:(NSString *)path;

@end
