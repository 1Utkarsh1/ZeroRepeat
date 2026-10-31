const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const socket = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer {
        if (socket >= 0) _ = std.c.close(socket);
    }
    var address: std.posix.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    const result = if (socket < 0) @as(c_int, -1) else std.c.connect(socket, @ptrCast(&address), @sizeOf(@TypeOf(address)));
    if (result < 0) {
        const message = try std.fmt.allocPrint(init.arena.allocator(), "denied:{t}", .{std.posix.errno(result)});
        try std.Io.File.stdout().writeStreamingAll(init.io, message);
        return;
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "connected");
}
