const std = @import("std");
const core = @import("zerorepeat");
const options = @import("test_paths");

test "SIGKILL at staged and swapped edit boundaries preserves source and forbids replay after reopen" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "staged", "after_exchange" }, 0..) |point, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buffer);
        const root = buffer[0..length];
        const path = try std.fmt.allocPrintSentinel(a, "{s}/journal.sqlite", .{root}, 0);
        defer a.free(path);
        try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old\n" });
        var child = try std.process.spawn(io, .{ .argv = &.{ options.crash_fixture, root, path, point }, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit });
        defer child.kill(io);
        const term = try child.wait(io);
        try std.testing.expect(term == .signal and term.signal == .KILL);
        var ctx = try core.context.Context.open(path, .{});
        defer ctx.close();
        var repo = try core.repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
        defer repo.close();
        try repo.recoverAfterOwnerExit();
        try std.testing.expectEqual(@as(i64, 1), try ctx.database.number("SELECT count(*) FROM edit_batches WHERE state='attention' AND diagnostic='OwnerExited';", &.{}));
        const target = try tmp.dir.readFileAlloc(io, "main.zig", a, .limited(4096));
        defer a.free(target);
        try std.testing.expectEqualStrings(if (index == 0) "old\n" else "new\n", target);
        var entry = try ctx.database.prepare("SELECT recovery_name FROM edit_entries WHERE batch_id=1;");
        defer entry.deinit();
        try std.testing.expect(try entry.step());
        const retained = try tmp.dir.readFileAlloc(io, entry.text(0), a, .limited(4096));
        defer a.free(retained);
        try std.testing.expectEqualStrings(if (index == 0) "new\n" else "old\n", retained);
        var current = try repo.read(a, "main.zig", null);
        defer current.deinit(a);
        try std.testing.expectError(error.EditNeedsReview, repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &.{.{ .path = "main.zig", .ref = current.ref, .replacements = &.{.{ .start = 0, .end = 3, .text = "next" }} }} }, null));
        try std.testing.expectEqual(@as(i64, 1), try ctx.database.number("SELECT count(*) FROM edit_batches;", &.{}));
        try std.testing.expectEqual(@as(i64, 0), try ctx.database.number("SELECT count(*) FROM pragma_foreign_key_check;", &.{}));
    }
}
