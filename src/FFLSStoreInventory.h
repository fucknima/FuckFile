#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Parses the CoreServicesStore Bundle table structurally and resolves each
// LSBundleBaseData.exactIdentifier through the store's <string> table.
//
// complete=YES means every live Bundle record in the selected store produced a
// syntactically valid identifier; callers may then skip the legacy byte-string
// candidate scan. complete=NO is fail-closed and callers must retain their
// existing conservative fallback.
NSArray<NSString *> *FFLSStoreBundleIdentifiers(NSString *lsdContainerRoot,
                                                BOOL * _Nullable complete,
                                                NSUInteger * _Nullable recordCount);

// Test hook: parses one already-loaded CoreServicesStore blob using the same
// production parser. This is intentionally public only to the project test
// target; app code should use FFLSStoreBundleIdentifiers.
NSArray<NSString *> *FFLSStoreBundleIdentifiersFromData(NSData *data,
                                                        BOOL * _Nullable complete,
                                                        NSUInteger * _Nullable recordCount);

NS_ASSUME_NONNULL_END
