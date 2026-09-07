#import <UIKit/UIKit.h>
#import "FFArchiveCreate.h"

NS_ASSUME_NONNULL_BEGIN

@interface FFArchiveCreateOptionsViewController : UITableViewController

- (instancetype)initWithSuggestedName:(NSString *)suggestedName
                            itemCount:(NSUInteger)itemCount
                           completion:(void (^)(NSString *archiveName,
                                                FFArchiveCreateOptions *options))completion;

@end

NS_ASSUME_NONNULL_END
