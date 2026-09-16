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

// Read-write connection used by the record editor and the SQL console's
// write mode. Browsing stays on the read-only connection.
- (nullable instancetype)initEditableWithDatabasePath:(NSString *)path error:(NSError **)error;
@property(nonatomic, readonly) BOOL editable;
@property(nonatomic, copy, readonly) NSString *databasePath;

// NO for WITHOUT ROWID tables (row editing has no stable identity there).
- (BOOL)tableHasRowID:(NSString *)table;

// Executes the statements inside BEGIN IMMEDIATE … COMMIT with automatic
// ROLLBACK on any failure. changedRows receives sqlite3_changes of the last
// statement that modified rows.
- (BOOL)applyStatementsInTransaction:(NSArray<NSString *> *)statements
                         changedRows:(NSInteger *)changedRows
                               error:(NSError **)error;

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
