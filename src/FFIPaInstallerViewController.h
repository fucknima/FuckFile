#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// IPA installer page: parses Payload/*.app out of the archive, shows app
// metadata (name / bundle id / version / build / min iOS / icon) and an
// install action whose result reflects the real environment — this jailed
// build has no installation backend, so the button explains exactly why
// instead of faking success.
@interface FFIPaInstallerViewController : UITableViewController

- (nullable instancetype)initWithIpaPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
