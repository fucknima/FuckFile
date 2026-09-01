#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFAppDataRegistryDidChangeNotification;

// Persistent logical inventory for AppData. The registry stores only stable
// identifiers and locally obtained display names. It deliberately does not
// persist online-name overlays, container UUIDs, sandbox tokens or MCM leases.
@interface FFAppDataRegistry : NSObject

+ (instancetype)sharedRegistry;

@property(nonatomic, readonly) NSArray<NSString *> *identifiers;

- (nullable NSString *)displayNameForIdentifier:(NSString *)identifier;
- (BOOL)containsIdentifier:(NSString *)identifier;

// Returns YES when the registry changed. A transient local fallback equal to
// the Bundle ID never downgrades an already known readable local name.
- (BOOL)registerIdentifier:(NSString *)identifier
               displayName:(nullable NSString *)displayName;

// Removes identifiers that have been positively reconciled as no longer
// installed. The operation is batched so UI observers receive one refresh.
- (NSUInteger)removeIdentifiers:(NSArray<NSString *> *)identifiers;

// Creates the logical AppData root when advanced access is active and migrates
// legacy per-app symlinks into the registry. Legacy symlinks are then removed:
// they are process-session materializations, not persistent source-of-truth.
- (void)prepareVirtualRootAndMigrateLegacyLinks;

@end

NS_ASSUME_NONNULL_END
