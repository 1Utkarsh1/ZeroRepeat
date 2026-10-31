const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const os = builtin.os.tag;

pub const Identity = struct {
    bytes: [80]u8 = undefined,
    len: usize,

    pub fn text(self: *const Identity) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Metadata = struct {
    stat: Io.File.Stat,
    identity: Identity,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

pub fn metadata(file: Io.File, io: Io) !Metadata {
    if (os != .macos and os != .linux) return error.UnsupportedPlatform;
    var id: Identity = .{ .len = 0 };
    if (os == .linux) {
        const linux = std.os.linux;
        var raw: linux.Statx = undefined;
        var request = Io.Threaded.linux_statx_request;
        request.UID = true;
        request.GID = true;
        if (linux.errno(linux.statx(file.handle, "", linux.AT.EMPTY_PATH, request, &raw)) != .SUCCESS or !raw.mask.UID or !raw.mask.GID) return error.MetadataUnavailable;
        id.len = (try std.fmt.bufPrint(&id.bytes, "{d}:{d}:{d}", .{ raw.dev_major, raw.dev_minor, raw.ino })).len;
        return .{ .stat = try Io.Threaded.statFromLinux(&raw), .identity = id, .uid = raw.uid, .gid = raw.gid };
    } else {
        var raw: std.c.Stat = undefined;
        if (std.posix.errno(std.c.fstat(file.handle, &raw)) != .SUCCESS) return error.MetadataUnavailable;
        id.len = (try std.fmt.bufPrint(&id.bytes, "{d}:{d}", .{ raw.dev, raw.ino })).len;
        return .{ .stat = try file.stat(io), .identity = id, .uid = raw.uid, .gid = raw.gid };
    }
}

pub fn directoryFile(dir: Io.Dir) Io.File {
    return .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
}

/// No-follow, nonblocking open also avoids hanging on a raced-in FIFO.
pub fn openRegular(dir: Io.Dir, io: Io, name: [:0]const u8) !Io.File {
    const observed = try dir.statFile(io, name, .{ .follow_symlinks = false });
    if (observed.kind != .file) return error.NotRegularFile;
    const fd = std.c.openat(dir.handle, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .NOCTTY = true });
    if (fd < 0) return error.FileOpenFailed;
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    errdefer file.close(io);
    const info = try metadata(file, io);
    if (info.stat.kind != .file or info.stat.nlink != 1) return error.NotSingleLinkFile;
    return file;
}

pub fn identity(dir: Io.Dir, io: Io) !Identity {
    return (try metadata(directoryFile(dir), io)).identity;
}

pub fn same(a: Metadata, b: Metadata) bool {
    return std.mem.eql(u8, a.identity.text(), b.identity.text()) and a.uid == b.uid and a.gid == b.gid and a.stat.size == b.stat.size and
        a.stat.permissions.toMode() == b.stat.permissions.toMode() and a.stat.mtime.nanoseconds == b.stat.mtime.nanoseconds and
        a.stat.ctime.nanoseconds == b.stat.ctime.nanoseconds and a.stat.nlink == b.stat.nlink;
}

pub fn read(allocator: std.mem.Allocator, io: Io, file: Io.File, maximum: usize) !struct { body: []u8, meta: Metadata } {
    const before = try metadata(file, io);
    if (before.stat.kind != .file or before.stat.nlink != 1) return error.NotSingleLinkFile;
    if (before.stat.size > maximum) return error.FileTooLarge;
    const body = try allocator.alloc(u8, @intCast(before.stat.size));
    errdefer allocator.free(body);
    if (try file.readPositionalAll(io, body, 0) != body.len) return error.FileChanged;
    var extra: [1]u8 = undefined;
    if (try file.readPositional(io, &.{&extra}, body.len) != 0) return error.FileChanged;
    const after = try metadata(file, io);
    if (!same(before, after)) return error.FileChanged;
    return .{ .body = body, .meta = after };
}

const attrs = if (os == .macos) struct {
    extern "c" fn flistxattr(c_int, ?[*]u8, usize, c_int) isize;
    extern "c" fn fgetxattr(c_int, [*:0]const u8, ?[*]u8, usize, u32, c_int) isize;
    extern "c" fn fcopyfile(c_int, c_int, ?*anyopaque, u32) c_int;
    extern "c" fn acl_get_fd_np(c_int, c_int) ?*anyopaque;
    extern "c" fn acl_size(*anyopaque) isize;
    extern "c" fn acl_copy_ext(?*anyopaque, *anyopaque, isize) isize;
    extern "c" fn acl_free(*anyopaque) c_int;
} else struct {
    extern "c" fn flistxattr(c_int, ?[*]u8, usize) isize;
    extern "c" fn fgetxattr(c_int, [*:0]const u8, ?[*]u8, usize) isize;
    extern "c" fn fsetxattr(c_int, [*:0]const u8, [*]const u8, usize, c_int) c_int;
};

/// Private execution roots cannot inherit broader ACL permissions.
pub fn requirePrivateDirectory(dir: Io.Dir, io: Io) !void {
    const file = directoryFile(dir);
    const info = try metadata(file, io);
    if (info.stat.kind != .directory or info.uid != std.c.getuid() or info.stat.permissions.toMode() & 0o777 != 0o700) return error.InvalidScratchParent;
    if (os == .macos) {
        if (attrs.acl_get_fd_np(file.handle, 0x100)) |acl| {
            _ = attrs.acl_free(acl);
            return error.UnsupportedScratchAcl;
        }
        if (std.posix.errno(@as(c_int, -1)) != .NOENT) return error.MetadataUnavailable;
    } else {
        for ([_][:0]const u8{ "system.posix_acl_access", "system.posix_acl_default" }) |name| {
            if (attrs.fgetxattr(file.handle, name, null, 0) >= 0) return error.UnsupportedScratchAcl;
            if (std.posix.errno(@as(c_int, -1)) != .NODATA) return error.MetadataUnavailable;
        }
    }
}

pub fn writableMetadata(file: Io.File, io: Io) !Metadata {
    const info = try metadata(file, io);
    if (info.stat.kind != .file or info.stat.nlink != 1 or info.uid != std.c.getuid()) return error.UnsupportedFileMetadata;
    if (info.stat.permissions.toMode() & 0o7000 != 0) return error.UnsupportedFileMetadata;
    return info;
}

fn names(allocator: std.mem.Allocator, file: Io.File) ![]const [:0]const u8 {
    const count = if (os == .macos) attrs.flistxattr(file.handle, null, 0, 0) else attrs.flistxattr(file.handle, null, 0);
    if (count < 0 or count > 64 * 1024) return error.MetadataUnavailable;
    const buffer = try allocator.alloc(u8, @intCast(count));
    const actual = if (os == .macos) attrs.flistxattr(file.handle, buffer.ptr, buffer.len, 0) else attrs.flistxattr(file.handle, buffer.ptr, buffer.len);
    if (actual != count) return error.FileChanged;
    var result: std.ArrayList([:0]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, buffer, 0);
    while (parts.next()) |name| if (name.len > 0) try result.append(allocator, try allocator.dupeSentinel(u8, name, 0));
    std.sort.heap([:0]const u8, result.items, {}, struct {
        fn less(_: void, left: [:0]const u8, right: [:0]const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    return result.toOwnedSlice(allocator);
}

fn value(allocator: std.mem.Allocator, file: Io.File, name: [:0]const u8) ![]u8 {
    const size = if (os == .macos) attrs.fgetxattr(file.handle, name, null, 0, 0, 0) else attrs.fgetxattr(file.handle, name, null, 0);
    if (size < 0 or size > 1024 * 1024) return error.MetadataUnavailable;
    const bytes = try allocator.alloc(u8, @intCast(size));
    const actual = if (os == .macos) attrs.fgetxattr(file.handle, name, bytes.ptr, bytes.len, 0, 0) else attrs.fgetxattr(file.handle, name, bytes.ptr, bytes.len);
    if (actual != size) return error.FileChanged;
    return bytes;
}

pub fn signature(allocator: std.mem.Allocator, io: Io, file: Io.File) ![32]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try metadata(file, io);
    var hash: std.crypto.hash.Blake3 = .init(.{});
    var prefix: [96]u8 = undefined;
    hash.update(try std.fmt.bufPrint(&prefix, "{d}:{d}:{d};", .{ before.uid, before.gid, before.stat.permissions.toMode() }));
    var total: usize = 0;
    for (try names(a, file)) |name| {
        const bytes = try value(a, file, name);
        total += bytes.len;
        if (total > 1024 * 1024) return error.MetadataUnavailable;
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, bytes.len, .little);
        hash.update(name);
        hash.update(&.{0});
        hash.update(&size);
        hash.update(bytes);
    }
    if (os == .macos) {
        if (attrs.acl_get_fd_np(file.handle, 0x100)) |acl| {
            defer _ = attrs.acl_free(acl);
            const count = attrs.acl_size(acl);
            if (count < 0 or count > 64 * 1024) return error.MetadataUnavailable;
            const bytes = try a.alloc(u8, @intCast(count));
            @memset(bytes, 0);
            if (attrs.acl_copy_ext(bytes.ptr, acl, count) != count) return error.MetadataUnavailable;
            hash.update("acl:");
            hash.update(bytes);
        } else {
            if (std.posix.errno(@as(c_int, -1)) != .NOENT) return error.MetadataUnavailable;
            hash.update("no-acl");
        }
    }
    if (!same(before, try metadata(file, io))) return error.FileChanged;
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

pub fn copyMetadata(allocator: std.mem.Allocator, io: Io, source: Io.File, destination: Io.File) !void {
    const info = try writableMetadata(source, io);
    if (os == .macos) {
        if (attrs.fcopyfile(source.handle, destination.handle, null, 7) != 0) return error.MetadataCopyFailed;
    } else {
        if (std.c.fchown(destination.handle, info.uid, info.gid) != 0) return error.MetadataCopyFailed;
        try destination.setPermissions(io, .fromMode(info.stat.permissions.toMode() & 0o777));
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        for (try names(a, source)) |name| {
            const bytes = try value(a, source, name);
            if (attrs.fsetxattr(destination.handle, name, bytes.ptr, bytes.len, 0) != 0) return error.MetadataCopyFailed;
        }
    }
    if (!std.mem.eql(u8, &(try signature(allocator, io, source)), &(try signature(allocator, io, destination)))) return error.MetadataCopyFailed;
}

pub fn syncFile(file: Io.File, io: Io) !void {
    try file.sync(io);
    if (os == .macos and std.posix.errno(std.c.fcntl(file.handle, std.c.F.FULLFSYNC)) != .SUCCESS) return error.FullSyncFailed;
}

pub fn syncDirectory(dir: Io.Dir, io: Io) !void {
    try directoryFile(dir).sync(io);
}

/// Exchange is not idempotent; an error must never trigger an automatic retry.
pub fn exchange(dir: Io.Dir, old: [:0]const u8, new: [:0]const u8) !void {
    const status = switch (os) {
        .macos => std.posix.errno(std.c.renameatx_np(dir.handle, old, dir.handle, new, .{ .SWAP = true })),
        .linux => std.os.linux.errno(std.os.linux.renameat2(dir.handle, old, dir.handle, new, .{ .EXCHANGE = true })),
        else => return error.UnsupportedPlatform,
    };
    switch (status) {
        .SUCCESS => {},
        .INVAL, .NOSYS, .OPNOTSUPP => return error.ExchangeUnsupported,
        .XDEV => return error.CrossDevice,
        else => return error.ExchangeFailed,
    }
}
