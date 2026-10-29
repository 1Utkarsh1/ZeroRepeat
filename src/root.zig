pub const db = @import("db.zig");
pub const context = @import("context.zig");
pub const continuity = @import("continuity.zig");
pub const provider_stream = @import("provider_stream.zig");
pub const context_tools = @import("context_tools.zig");

test {
    _ = db;
    _ = context;
    _ = continuity;
    _ = provider_stream;
    _ = context_tools;
    _ = @import("context_tests.zig");
    _ = @import("context_state_tests.zig");
    _ = @import("provider_context_tests.zig");
}

test "bundled SQLite version and required compilation features are present" {
    const std = @import("std");
    var database = try db.Db.open(":memory:");
    defer database.close();
    var row = try database.prepare("SELECT sqlite_version(),sqlite_compileoption_used('ENABLE_FTS5'),sqlite_compileoption_used('THREADSAFE=1'),sqlite_compileoption_used('OMIT_LOAD_EXTENSION');");
    defer row.deinit();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings("3.54.1", row.text(0));
    for (1..4) |column| try std.testing.expectEqual(@as(i64, 1), row.int(@intCast(column)));
}
