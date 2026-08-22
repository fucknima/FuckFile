#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Read-only SQLite access for the SQLite3 viewer: database metadata,
// tables/views/indexes, schema text and paged row browsing plus free-form
// SQL queries. The database is opened with SQLITE_OPEN_READONLY and the
// file is never modified through this service (WAL/SHM sidecars are left
// to SQLite itself).
@interface FFSQLiteService : NSObject

// Returns nil and sets *error when the file cannot be opened as a
// database (missing, locked-forever, malformed, not a database…).
- (nullable instancetype)initWithDatabasePath:(NSString *)path error:(NSError **)error;
- (void)close;

- (NSDictionary<NSString *, NSString *> *)databaseInfo; // page size / encoding / counts
- (NSArray<NSString *> *)tableNames;   // user tables only (no sqlite_*)
- (NSArray<NSString *> *)viewNames;
- (NSArray<NSString *> *)indexNamesForTable:(NSString *)table;

// CREATE statement from sqlite_master; nil when the object is gone.
- (nullable NSString *)schemaSQLForObject:(NSString *)name;

// Runs an arbitrary SELECT and returns up to limit rows starting at
// offset. Column names are returned in *columns. Any SQLite error
// (busy/locked/corrupt/…) is mapped into *error.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)rowsForQuery:(NSString *)sql
    limit:(NSUInteger)limit offset:(NSUInteger)offset
    outColumns:(NSArray<NSString *> * _Nullable * _Nullable)columns
    error:(NSError * _Nullable * _Nullable)error;

// SELECT COUNT(*) for a table name (quoted); -1 on error.
- (long long)rowCountForTable:(NSString *)table;

@end

NS_ASSUME_NONNULL_END
