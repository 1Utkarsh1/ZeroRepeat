const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Reason = enum { exited, timed_out, output_limit, canceled };
pub const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    reason: Reason,

    pub fn deinit(self: *Captured, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

extern "c" fn waitid(c_uint, c_uint, *std.c.siginfo_t, c_int) c_int;

fn exited(pid: std.posix.pid_t) !bool {
    var info: std.c.siginfo_t = std.mem.zeroes(std.c.siginfo_t);
    const options: c_int = if (builtin.os.tag == .macos) 0x1 | 0x4 | 0x20 else std.os.linux.W.NOHANG | std.os.linux.W.EXITED | std.os.linux.W.NOWAIT;
    // WNOWAIT retains the owned PID until group cleanup, avoiding identifier reuse.
    if (waitid(1, @intCast(pid), &info, options) != 0) return error.ChildStatusUnavailable;
    return (if (builtin.os.tag == .macos) info.pid else info.fields.common.first.piduid.pid) != 0;
}

pub fn signalOwned(child: *const std.process.Child) void {
    // shortcut: macOS groups cannot contain descendants that change sessions; use PID namespaces for hostile trees.
    if (child.id) |pid| {
        _ = std.c.kill(-pid, .KILL);
        _ = std.c.kill(pid, .KILL);
    }
}

pub fn terminate(child: *std.process.Child, io: Io) void {
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    signalOwned(child);
    child.kill(io);
}

/// Drains both pipes under a fixed deadline; caller has spawned pgid=0.
pub fn capture(child: *std.process.Child, allocator: Allocator, io: Io, deadline: Io.Clock.Timestamp, limit: usize) !Captured {
    var storage: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(allocator, io, storage.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer {
        const previous = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(previous);
        signalOwned(child);
        reader.deinit();
        child.kill(io);
    }
    var reason: Reason = .exited;
    while (true) {
        reader.fill(1024, .{ .deadline = deadline }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                reason = .timed_out;
                break;
            },
            error.Canceled => {
                reason = .canceled;
                break;
            },
            else => return err,
        };
        if (reader.reader(0).bufferedLen() > limit or reader.reader(1).bufferedLen() > limit) {
            reason = .output_limit;
            break;
        }
    }
    if (reason == .exited) {
        try reader.checkAnyError();
        while (!try exited(child.id.?)) {
            io.checkCancel() catch {
                reason = .canceled;
                break;
            };
            if (Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) {
                reason = .timed_out;
                break;
            }
            io.sleep(.fromMilliseconds(2), .awake) catch {
                reason = .canceled;
                break;
            };
        }
    }
    signalOwned(child);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    reader.batch.cancel(io);
    const output = try allocator.dupe(u8, reader.reader(0).buffered()[0..@min(limit, reader.reader(0).bufferedLen())]);
    errdefer allocator.free(output);
    const diagnostic = try allocator.dupe(u8, reader.reader(1).buffered()[0..@min(limit, reader.reader(1).bufferedLen())]);
    errdefer allocator.free(diagnostic);
    const term = try child.wait(io);
    return .{ .stdout = output, .stderr = diagnostic, .term = term, .reason = reason };
}
