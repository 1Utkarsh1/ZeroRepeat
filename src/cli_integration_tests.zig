const std = @import("std");
const options = @import("cli_options");

test "successive CLI commands preserve prior redirected output and the shared file offset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "shared-stdout.txt", .{ .read = true });
    defer file.close(io);
    const prefix = "earlier command output\n";
    try file.writeStreamingAll(io, prefix);
    for (0..2) |_| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ options.executable, "version" },
            .stdin = .ignore,
            .stdout = .{ .file = file },
            .stderr = .inherit,
        });
        defer child.kill(io);
        try std.testing.expect((try child.wait(io)).success());
    }
    const bytes = try temp.dir.readFileAlloc(io, "shared-stdout.txt", allocator, .limited(8192));
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, prefix));
    const payload = bytes[prefix.len..];
    try std.testing.expect(payload.len > 0 and payload.len % 2 == 0);
    const half = payload.len / 2;
    try std.testing.expect(std.mem.startsWith(u8, payload, "ZeroRepeat "));
    try std.testing.expectEqualStrings(payload[0..half], payload[half..]);
}
