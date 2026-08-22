#import "FFSQLiteService.h"

#import <sqlite3.h>

static NSError *FFSQLiteError(int code, NSString *message)
{
    NSString *friendly;
    switch (code) {
        case SQLITE_BUSY:
        case SQLITE_LOCKED:
            friendly = [NSString stringWithFormat:@"%@（数据库被占用，稍后重试）", message];
            break;
        case SQLITE_CORRUPT:
        case SQLITE_NOTADB:
            friendly = @"文件不是有效的 SQLite 数据库或已损坏";
            break;
        case SQLITE_CANTOPEN:
            friendly = @"无法打开数据库文件";
            break;
        default:
            friendly = message ?: [NSString stringWithFormat:@"SQLite 错误 %d", code];
    }
    return [NSError errorWithDomain:@"FFSQLite" code:code
        userInfo:@{NSLocalizedDescriptionKey: friendly}];
}

@implementation FFSQLiteService
{
    sqlite3 *_db;
}

- (instancetype)initWithDatabasePath:(NSString *)path error:(NSError **)error
{
    self = [super init];
    if (!self) return nil;
    _db = NULL;
    int rc = sqlite3_open_v2(path.fileSystemRepresentation, &_db,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
    if (rc != SQLITE_OK) {
        if (error)
            *error = FFSQLiteError(rc,
                _db ? [NSString stringWithUTF8String:sqlite3_errmsg(_db)] : nil);
        if (_db) sqlite3_close(_db);
        _db = NULL;
        return nil;
    }
    // WAL 数据库以只读打开时依赖 -wal/-shm 可访问；同容器内通常成立。
    return self;
}

- (void)dealloc
{
    [self close];
}

- (void)close
{
    if (_db) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)simpleResults:(NSString *)sql error:(NSError **)error
{
    NSMutableArray *rows = [NSMutableArray array];
    sqlite3_stmt *statement = NULL;
    int rc = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &statement, NULL);
    if (rc != SQLITE_OK) {
        if (error) *error = FFSQLiteError(rc,
            [NSString stringWithUTF8String:sqlite3_errmsg(_db)]);
        return nil;
    }
    while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (int col = 0; col < sqlite3_column_count(statement); col++) {
            const unsigned char *text = sqlite3_column_text(statement, col);
            row[@(col)] = text ? [NSString stringWithUTF8String:(const char *)text] : @"";
        }
        [rows addObject:row];
    }
    sqlite3_finalize(statement);
    if (rc != SQLITE_DONE) {
        if (error) *error = FFSQLiteError(rc,
            [NSString stringWithUTF8String:sqlite3_errmsg(_db)]);
        return nil;
    }
    return rows;
}

- (NSDictionary<NSString *, NSString *> *)databaseInfo
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    int pageSize = 0, encoding = 0;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, "PRAGMA page_size", -1, &statement, NULL) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW)
        pageSize = sqlite3_column_int(statement, 0);
    sqlite3_finalize(statement);
    if (sqlite3_prepare_v2(_db, "PRAGMA encoding", -1, &statement, NULL) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char *enc = sqlite3_column_text(statement, 0);
        [lines addObject:enc ? [NSString stringWithUTF8String:(const char *)enc]
                             : @"未知编码"];
    }
    sqlite3_finalize(statement);
    if (sqlite3_prepare_v2(_db, "PRAGMA user_version", -1, &statement, NULL) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW)
        encoding = sqlite3_column_int(statement, 0);
    sqlite3_finalize(statement);

    NSArray<NSString *> *tables = self.tableNames;
    NSArray<NSString *> *views = self.viewNames;
    return @{
        @"summary": [NSString stringWithFormat:
            @"页大小 %d 字节 · %@ · user_version %d\n%lu 张表 · %lu 个视图",
            pageSize, lines.firstObject ?: @"?", encoding,
            (unsigned long)tables.count, (unsigned long)views.count],
    };
}

- (NSArray<NSString *> *)objectNamesOfType:(NSString *)type
{
    NSArray *rows = [self simpleResults:[NSString stringWithFormat:
        @"SELECT name FROM sqlite_master WHERE type='%@' AND name NOT LIKE 'sqlite_%%' ORDER BY name", type]
        error:nil];
    if (!rows) return @[];
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *row in rows) [names addObject:row[@(0)] ?: @""];
    return names;
}

- (NSArray<NSString *> *)tableNames { return [self objectNamesOfType:@"table"]; }

- (NSArray<NSString *> *)viewNames { return [self objectNamesOfType:@"view"]; }

- (NSArray<NSString *> *)indexNamesForTable:(NSString *)table
{
    NSArray *rows = [self simpleResults:[NSString stringWithFormat:
        @"PRAGMA index_list('%@')", [table stringByReplacingOccurrencesOfString:@"'" withString:@"''"]]
        error:nil];
    if (!rows) return @[];
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSString *name = row[@(1)];
        if (name.length) [names addObject:name];
    }
    return names;
}

// 索引名列表返回的是 index_list 的第二列（name），这里补一个按名的取列结构。
- (NSString *)schemaSQLForObject:(NSString *)name
{
    NSString *safe = [name stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
    NSArray *rows = [self simpleResults:[NSString stringWithFormat:
        @"SELECT sql FROM sqlite_master WHERE name='%@'", safe] error:nil];
    return rows.firstObject[@(0)];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)rowsForQuery:(NSString *)sql
    limit:(NSUInteger)limit offset:(NSUInteger)offset
    outColumns:(NSArray<NSString *> **)columns error:(NSError **)error
{
    if (columns) *columns = nil;
    sqlite3_stmt *statement = NULL;
    int rc = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &statement, NULL);
    if (rc != SQLITE_OK) {
        if (error) *error = FFSQLiteError(rc,
            [NSString stringWithUTF8String:sqlite3_errmsg(_db)]);
        return nil;
    }
    int columnCount = sqlite3_column_count(statement);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int col = 0; col < columnCount; col++) {
        const char *label = sqlite3_column_name(statement, col);
        [names addObject:label ? @(label) :
            [NSString stringWithFormat:@"列%d", col]];
    }
    if (columns) *columns = names;

    for (NSUInteger skipped = 0; skipped < offset; skipped++)
        if (sqlite3_step(statement) != SQLITE_ROW) break;

    NSMutableArray *rows = [NSMutableArray array];
    while ((NSUInteger)rows.count < MAX(limit, 1) &&
           (rc = sqlite3_step(statement)) == SQLITE_ROW) {
        NSMutableDictionary<NSString *, NSString *> *row =
            [NSMutableDictionary dictionary];
        for (int col = 0; col < columnCount; col++) {
            const unsigned char *text = sqlite3_column_text(statement, col);
            row[names[col]] = text ? [NSString stringWithUTF8String:(const char *)text] : @"";
        }
        [rows addObject:row];
    }
    sqlite3_finalize(statement);
    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
        if (error) *error = FFSQLiteError(rc,
            [NSString stringWithUTF8String:sqlite3_errmsg(_db)]);
        return nil;
    }
    return rows;
}

- (long long)rowCountForTable:(NSString *)table
{
    NSString *safe = [table stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
    NSArray *rows = [self simpleResults:[NSString stringWithFormat:
        @"SELECT COUNT(*) FROM \"%@\"", safe] error:nil];
    NSDictionary *firstRow = rows.firstObject;
    if (!firstRow) return -1;
    NSNumber *count = firstRow[@(0)];
    return count ? count.longLongValue : -1;
}

@end
