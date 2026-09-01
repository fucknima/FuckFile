#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FFPlistValueCommitHandler)(id newValue);

// Dedicated scalar editor used by the structured plist browser. It never writes
// the file directly; a successful edit only updates the shared FFPlistDocument.
@interface FFPlistValueEditorViewController : UIViewController

- (instancetype)initWithValue:(id)value
                         title:(NSString *)title
                 commitHandler:(FFPlistValueCommitHandler)commitHandler;

@end

NS_ASSUME_NONNULL_END
