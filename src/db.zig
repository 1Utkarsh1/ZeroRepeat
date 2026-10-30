const std = @import("std");
// Zig 0.17 removed @cImport; these stable declarations match sqlite3.h.
const c = struct {
    const sqlite3 = opaque {};
    const sqlite3_stmt = opaque {};
    const sqlite3_destructor_type = ?*align(1) const fn (?*anyopaque) callconv(.c) void;
    const SQLITE_OK = 0;
    const SQLITE_BUSY = 5;
    const SQLITE_LOCKED = 6;
    const SQLITE_NOMEM = 7;
    const SQLITE_READONLY = 8;
    const SQLITE_CORRUPT = 11;
    const SQLITE_TOOBIG = 18;
    const SQLITE_CONSTRAINT = 19;
    const SQLITE_MISUSE = 21;
    const SQLITE_RANGE = 25;
    const SQLITE_NOTADB = 26;
    const SQLITE_ROW = 100;
    const SQLITE_DONE = 101;
    const SQLITE_NULL = 5;
    const SQLITE_OPEN_READWRITE = 0x00000002;
    const SQLITE_OPEN_CREATE = 0x00000004;
    const SQLITE_OPEN_FULLMUTEX = 0x00010000;
    const SQLITE_OPEN_NOFOLLOW = 0x01000000;

    extern "c" fn sqlite3_open_v2([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) c_int;
    extern "c" fn sqlite3_close_v2(*sqlite3) c_int;
    extern "c" fn sqlite3_busy_timeout(*sqlite3, c_int) c_int;
    extern "c" fn sqlite3_exec(*sqlite3, [*:0]const u8, ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int, ?*anyopaque, ?*[*c]u8) c_int;
    extern "c" fn sqlite3_prepare_v2(*sqlite3, [*:0]const u8, c_int, *?*sqlite3_stmt, ?*[*c]const u8) c_int;
    extern "c" fn sqlite3_errmsg(*sqlite3) [*:0]const u8;
    extern "c" fn sqlite3_get_autocommit(*sqlite3) c_int;
    extern "c" fn sqlite3_finalize(*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_bind_text(*sqlite3_stmt, c_int, [*]const u8, c_int, sqlite3_destructor_type) c_int;
    extern "c" fn sqlite3_bind_blob(*sqlite3_stmt, c_int, *const anyopaque, c_int, sqlite3_destructor_type) c_int;
    extern "c" fn sqlite3_bind_int64(*sqlite3_stmt, c_int, i64) c_int;
    extern "c" fn sqlite3_bind_null(*sqlite3_stmt, c_int) c_int;
    extern "c" fn sqlite3_step(*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_reset(*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_clear_bindings(*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_column_text(*sqlite3_stmt, c_int) [*c]const u8;
    extern "c" fn sqlite3_column_blob(*sqlite3_stmt, c_int) ?*const anyopaque;
    extern "c" fn sqlite3_column_bytes(*sqlite3_stmt, c_int) c_int;
    extern "c" fn sqlite3_column_int64(*sqlite3_stmt, c_int) i64;
    extern "c" fn sqlite3_column_double(*sqlite3_stmt, c_int) f64;
    extern "c" fn sqlite3_column_type(*sqlite3_stmt, c_int) c_int;
};

pub const Error = error{
    Sqlite,
    SqliteBusy,
    SqliteConstraint,
    SqliteTooBig,
    SqliteReadOnly,
    SqliteCorrupt,
    SqliteMisuse,
    OutOfMemory,
};

pub const Arg = union(enum) { int: i64, text: []const u8, blob: []const u8, null };

fn check(code: c_int) Error!void {
    switch (code & 0xff) {
        c.SQLITE_OK => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => return error.SqliteBusy,
        c.SQLITE_CONSTRAINT => return error.SqliteConstraint,
        c.SQLITE_TOOBIG => return error.SqliteTooBig,
        c.SQLITE_READONLY => return error.SqliteReadOnly,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => return error.SqliteCorrupt,
        c.SQLITE_MISUSE, c.SQLITE_RANGE => return error.SqliteMisuse,
        c.SQLITE_NOMEM => return error.OutOfMemory,
        else => return error.Sqlite,
    }
}

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) Error!Db {
        var db = try openUnconfigured(path);
        errdefer db.close();
        try db.configureDurability();
        return db;
    }

    /// Inspect application ownership before changing an existing database's journal.
    pub fn openUnconfigured(path: [:0]const u8) Error!Db {
        var handle: ?*c.sqlite3 = null;
        const code = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX | c.SQLITE_OPEN_NOFOLLOW, null);
        if (code != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close_v2(h);
            try check(code);
        }
        var db: Db = .{ .handle = handle orelse return error.Sqlite };
        errdefer db.close();
        try check(c.sqlite3_busy_timeout(db.handle, 5000));
        return db;
    }

    pub fn configureDurability(self: *Db) Error!void {
        try self.exec("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;");
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close_v2(self.handle);
        self.* = undefined;
    }

    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        try check(c.sqlite3_exec(self.handle, sql.ptr, null, null, null));
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) Error!Statement {
        var handle: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        try check(c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &handle, &tail));
        const prepared = handle orelse return error.SqliteMisuse;
        errdefer _ = c.sqlite3_finalize(prepared);
        if (tail != null and std.mem.trim(u8, std.mem.span(tail), " \r\n\t;").len != 0) return error.SqliteMisuse;
        return .{ .handle = prepared };
    }

    pub fn statement(self: *Db, sql: [:0]const u8, args: []const Arg) !Statement {
        var result = try self.prepare(sql);
        errdefer result.deinit();
        for (args, 1..) |arg, index| switch (arg) {
            .int => |value| try result.bindInt(@intCast(index), value),
            .text => |value| try result.bindText(@intCast(index), value),
            .blob => |value| try result.bindBlob(@intCast(index), value),
            .null => try result.bindNull(@intCast(index)),
        };
        return result;
    }

    pub fn run(self: *Db, sql: [:0]const u8, args: []const Arg) !void {
        var stmt = try self.statement(sql, args);
        defer stmt.deinit();
        if (try stmt.step()) return error.UnexpectedRow;
    }

    pub fn number(self: *Db, sql: [:0]const u8, args: []const Arg) !i64 {
        var stmt = try self.statement(sql, args);
        defer stmt.deinit();
        if (!try stmt.step()) return error.NotFound;
        return stmt.int(0);
    }

    /// Borrowed until the connection's next SQLite call or close.
    pub fn lastError(self: *const Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    pub fn inTransaction(self: *const Db) bool {
        return c.sqlite3_get_autocommit(self.handle) == 0;
    }
};

pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    done: bool = false,
    failed: bool = false,

    const transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    pub fn bindText(self: *Statement, index: c_int, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(c_int)) return error.SqliteTooBig;
        try check(c.sqlite3_bind_text(self.handle, index, if (value.len == 0) "".ptr else value.ptr, @intCast(value.len), transient));
    }

    pub fn bindBlob(self: *Statement, index: c_int, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(c_int)) return error.SqliteTooBig;
        try check(c.sqlite3_bind_blob(self.handle, index, if (value.len == 0) "".ptr else value.ptr, @intCast(value.len), transient));
    }

    pub fn bindInt(self: *Statement, index: c_int, value: i64) Error!void {
        try check(c.sqlite3_bind_int64(self.handle, index, value));
    }

    pub fn bindNull(self: *Statement, index: c_int) Error!void {
        try check(c.sqlite3_bind_null(self.handle, index));
    }

    pub fn step(self: *Statement) Error!bool {
        if (self.failed) return error.SqliteMisuse;
        if (self.done) return false;
        const code = c.sqlite3_step(self.handle);
        if (code == c.SQLITE_ROW) return true;
        if (code == c.SQLITE_DONE) {
            self.done = true;
            return false;
        }
        self.failed = true;
        try check(code);
        unreachable;
    }

    /// Resets iteration and clears all parameters; reports the previous step error.
    pub fn reset(self: *Statement) Error!void {
        const code = c.sqlite3_reset(self.handle);
        self.done = false;
        self.failed = false;
        try check(c.sqlite3_clear_bindings(self.handle));
        try check(code);
    }

    /// Column values are borrowed until the next step/reset/deinit.
    pub fn text(self: *const Statement, column: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, column);
        const len = c.sqlite3_column_bytes(self.handle, column);
        return if (ptr == null or len == 0) "" else ptr[0..@intCast(len)];
    }

    pub fn blob(self: *const Statement, column: c_int) []const u8 {
        const ptr = c.sqlite3_column_blob(self.handle, column);
        const len = c.sqlite3_column_bytes(self.handle, column);
        return if (ptr == null or len == 0) "" else @as([*]const u8, @ptrCast(ptr.?))[0..@intCast(len)];
    }

    pub fn int(self: *const Statement, column: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, column);
    }

    pub fn float(self: *const Statement, column: c_int) f64 {
        return c.sqlite3_column_double(self.handle, column);
    }

    pub fn isNull(self: *const Statement, column: c_int) bool {
        return c.sqlite3_column_type(self.handle, column) == c.SQLITE_NULL;
    }
};

test "bindings copy text and binary bytes, empty blobs differ from NULL, DONE never repeats writes" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE samples (id INTEGER PRIMARY KEY, text TEXT, bytes BLOB, absent TEXT);");
    var insert = try db.prepare("INSERT INTO samples (text, bytes, absent) VALUES (?, ?, ?);");
    defer insert.deinit();
    var text = [_]u8{ 'a', '\'', 0, 'z' };
    var bytes = [_]u8{ 0, 255, 13, 10 };
    try insert.bindText(1, &text);
    try insert.bindBlob(2, &bytes);
    try insert.bindNull(3);
    text[0] = 'x';
    bytes[0] = 77;
    try std.testing.expect(!try insert.step());
    try std.testing.expect(!try insert.step());
    try insert.reset();
    try insert.bindText(1, "");
    try insert.bindBlob(2, "");
    try std.testing.expect(!try insert.step());

    var rows = try db.prepare("SELECT id, text, bytes, absent FROM samples ORDER BY id;");
    defer rows.deinit();
    try std.testing.expect(try rows.step());
    try std.testing.expectEqual(@as(i64, 1), rows.int(0));
    try std.testing.expectEqualSlices(u8, &.{ 'a', '\'', 0, 'z' }, rows.text(1));
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 13, 10 }, rows.blob(2));
    try std.testing.expect(rows.isNull(3));
    try std.testing.expect(try rows.step());
    try std.testing.expectEqual(@as(i64, 2), rows.int(0));
    try std.testing.expectEqualStrings("", rows.text(1));
    try std.testing.expectEqual(@as(usize, 0), rows.blob(2).len);
    try std.testing.expect(!rows.isNull(2));
    try std.testing.expect(rows.isNull(3));
    try std.testing.expect(!try rows.step());
}

test "constraint errors preserve original rows, rollback stays explicit, and lastError is useful" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT NOT NULL); INSERT INTO records VALUES (1, 'original');");
    try db.exec("BEGIN IMMEDIATE;");
    try db.exec("INSERT INTO records VALUES (2, 'uncommitted');");
    var insert = try db.prepare("INSERT INTO records VALUES (?, ?);");
    defer insert.deinit();
    try insert.bindInt(1, 1);
    try insert.bindText(2, "replacement");
    try std.testing.expectError(error.SqliteConstraint, insert.step());
    try std.testing.expect(std.mem.indexOf(u8, db.lastError(), "UNIQUE") != null);
    try std.testing.expectError(error.SqliteMisuse, insert.step());
    try std.testing.expectError(error.SqliteConstraint, insert.reset());
    try db.exec("ROLLBACK;");
    var rows = try db.prepare("SELECT value FROM records ORDER BY id;");
    defer rows.deinit();
    try std.testing.expect(try rows.step());
    try std.testing.expectEqualStrings("original", rows.text(0));
    try std.testing.expect(!try rows.step());
    try std.testing.expectError(error.Sqlite, db.exec("SELECT FROM missing;"));
    try std.testing.expectError(error.SqliteMisuse, db.prepare("SELECT 1; SELECT 2;"));
    try std.testing.expectError(error.SqliteMisuse, db.prepare(""));
}

test "foreign keys and durable settings are enabled" {
    var db = try Db.open(":memory:");
    defer db.close();
    var foreign_keys = try db.prepare("PRAGMA foreign_keys;");
    defer foreign_keys.deinit();
    try std.testing.expect(try foreign_keys.step());
    try std.testing.expectEqual(@as(i64, 1), foreign_keys.int(0));
    var sync = try db.prepare("PRAGMA synchronous;");
    defer sync.deinit();
    try std.testing.expect(try sync.step());
    try std.testing.expectEqual(@as(i64, 2), sync.int(0));
    try db.exec("CREATE TABLE parent (id INTEGER PRIMARY KEY); CREATE TABLE child (id INTEGER REFERENCES parent(id));");
    try std.testing.expectError(error.SqliteConstraint, db.exec("INSERT INTO child VALUES (1);"));
}

test "on-disk WAL commits survive reopen and unfinished transactions do not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buffer);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/records.sqlite", .{dir_buffer[0..dir_len]}, 0);
    defer std.testing.allocator.free(path);
    {
        var db = try Db.open(path);
        defer db.close();
        try db.exec("CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT); INSERT INTO records VALUES (1, 'committed');");
        var mode = try db.prepare("PRAGMA journal_mode;");
        defer mode.deinit();
        try std.testing.expect(try mode.step());
        try std.testing.expectEqualStrings("wal", mode.text(0));
        try db.exec("BEGIN IMMEDIATE; INSERT INTO records VALUES (2, 'unfinished');");
    }
    {
        var db = try Db.open(path);
        defer db.close();
        var rows = try db.prepare("SELECT value FROM records ORDER BY id;");
        defer rows.deinit();
        try std.testing.expect(try rows.step());
        try std.testing.expectEqualStrings("committed", rows.text(0));
        try std.testing.expect(!try rows.step());
    }
}
