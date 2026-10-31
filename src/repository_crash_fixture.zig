const std = @import("std");
const context = @import("context.zig");
const repository = @import("repository.zig");
pub const repository_fault_injection = true;
var selected: repository.FaultPoint = .after_exchange;

fn crash(point: repository.FaultPoint, _: std.Io.Dir, _: [:0]const u8, _: [:0]const u8) !void {
    if (point == selected) {
        _ = std.c.raise(.KILL);
        std.process.exit(93);
    }
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) return error.InvalidArguments;
    selected = std.meta.stringToEnum(repository.FaultPoint, args[3]) orelse return error.InvalidArguments;
    const db_path = try a.dupeSentinel(u8, args[2], 0);
    var ctx = try context.Context.open(db_path, .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, init.io, args[1], &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    var before = try repo.read(a, "main.zig", null);
    defer before.deinit(a);
    repository.fault_hook = crash;
    _ = try repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &.{.{ .path = "main.zig", .ref = before.ref, .replacements = &.{.{ .start = 0, .end = 3, .text = "new" }} }} }, null);
    return error.CrashPointNotReached;
}
