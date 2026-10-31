const std = @import("std");
const builtin = @import("builtin");
const context = @import("context.zig");
const filesystem = @import("repository_fs.zig");
const repository = @import("repository.zig");
pub const process = @import("execution_process.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Backend = enum { seatbelt, bubblewrap };
pub const Config = struct {
    workspace: []const u8,
    /// Caller-owned 0700 parent; the runtime grants a fresh private child, never this tree.
    scratch: []const u8,
    read_only: []const []const u8 = &.{},
    backend: Backend = if (builtin.os.tag == .macos) .seatbelt else .bubblewrap,
    timeout_ms: u32 = 60_000,
    output_bytes: usize = 1024 * 1024,
};
pub const Input = struct { generation: i64, argv: []const []const u8, timeout_ms: u32 = 60_000 };
pub const Result = struct { id: i64, reason: process.Reason, term_kind: []const u8, term_value: i64, stdout_bytes: usize, stderr_bytes: usize, incomplete: bool, redacted: bool, elapsed_ms: u64 };
const Directory = struct { path: []const u8, handle: Io.Dir, identity: filesystem.Identity };

pub const Execution = struct {
    ctx: *context.Context,
    io: Io,
    arena: std.heap.ArenaAllocator,
    workspace: Directory,
    scratch_parent: Directory,
    scratch_name: []const u8,
    scratch: Directory,
    read_only: []const Directory,
    backend: Backend,
    timeout_ms: u32,
    output_bytes: usize,
    scope: []const u8,

    /// The workspace is read-only to commands; writes are confined to separate scratch.
    // shortcut: general builds needing source-tree writes require an owned writable workspace before compatibility is claimed.
    pub fn open(ctx: *context.Context, allocator: Allocator, io: Io, config: Config) !Execution {
        if (config.read_only.len > 32 or config.timeout_ms == 0 or config.timeout_ms > 3_600_000 or config.output_bytes == 0 or config.output_bytes > 4 * 1024 * 1024) return error.InvalidExecutionPolicy;
        if ((config.backend == .seatbelt and builtin.os.tag != .macos) or (config.backend == .bubblewrap and builtin.os.tag != .linux)) return error.IsolationUnavailable;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const workspace = try openDirectory(ctx, a, io, config.workspace);
        errdefer workspace.handle.close(io);
        const scratch_parent = try openDirectory(ctx, a, io, config.scratch);
        errdefer scratch_parent.handle.close(io);
        if (covers(workspace.path, scratch_parent.path) or covers(scratch_parent.path, workspace.path)) return error.OverlappingExecutionRoots;
        try filesystem.requirePrivateDirectory(scratch_parent.handle, io);
        const grants = try a.alloc(Directory, config.read_only.len);
        var count: usize = 0;
        errdefer for (grants[0..count]) |grant| grant.handle.close(io);
        for (config.read_only, grants) |path, *grant| {
            grant.* = try openDirectory(ctx, a, io, path);
            count += 1;
            if (covers(grant.path, scratch_parent.path) or covers(scratch_parent.path, grant.path)) return error.OverlappingExecutionRoots;
        }
        var identity = try ctx.database.prepare("SELECT identity FROM identity WHERE id=1;");
        defer identity.deinit();
        if (!try identity.step()) return error.CorruptContent;
        const scope = try a.dupe(u8, identity.text(0));
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const name = try std.fmt.allocPrint(a, "run-{s}", .{std.fmt.bytesToHex(random, .lower)});
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ scratch_parent.path, name });
        try scratch_parent.handle.createDir(io, name, .fromMode(0o700));
        errdefer scratch_parent.handle.deleteDir(io, name) catch {};
        const scratch = try openDirectory(ctx, a, io, path);
        errdefer scratch.handle.close(io);
        try filesystem.requirePrivateDirectory(scratch.handle, io);
        return .{ .ctx = ctx, .io = io, .arena = arena, .workspace = workspace, .scratch_parent = scratch_parent, .scratch_name = name, .scratch = scratch, .read_only = grants, .backend = config.backend, .timeout_ms = config.timeout_ms, .output_bytes = config.output_bytes, .scope = scope };
    }

    pub fn close(self: *Execution) void {
        self.workspace.handle.close(self.io);
        // Remove only our empty child; retain nonempty caches/artifacts and all parent data.
        self.removeEmptyScratch();
        self.scratch.handle.close(self.io);
        self.scratch_parent.handle.close(self.io);
        for (self.read_only) |grant| grant.handle.close(self.io);
        self.arena.deinit();
        self.* = undefined;
    }

    fn removeEmptyScratch(self: *Execution) void {
        checkDirectory(self.io, self.scratch_parent) catch return;
        checkDirectory(self.io, self.scratch) catch return;
        self.scratch_parent.handle.deleteDir(self.io, self.scratch_name) catch {};
    }

    pub fn validate(self: *Execution, input: Input, secret: ?[]const u8) !void {
        if (input.argv.len == 0 or input.argv.len > 256 or input.timeout_ms == 0 or input.timeout_ms > self.timeout_ms) return error.InvalidCommand;
        if (!std.fs.path.isAbsolute(input.argv[0])) return error.AbsoluteExecutableRequired;
        var bytes: usize = 0;
        for (input.argv) |arg| {
            if (arg.len > 64 * 1024 or std.mem.indexOfScalar(u8, arg, 0) != null or !std.unicode.utf8ValidateSlice(arg)) return error.InvalidCommand;
            bytes = try std.math.add(usize, bytes, arg.len + 1);
            try repository.rejectSecret(secret, arg);
        }
        if (bytes > 64 * 1024) return error.CommandTooLarge;
        try self.checkRoots();
        const backend = backendPath(self.backend);
        Io.Dir.cwd().access(self.io, backend, .{ .execute = true }) catch return error.IsolationUnavailable;
    }

    pub fn run(self: *Execution, allocator: Allocator, input: Input, secret: ?[]const u8, action: ?i64, budget_deadline: ?Io.Clock.Timestamp) !Result {
        const started = Io.Clock.Timestamp.now(self.io, .awake);
        var deadline = started.addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(input.timeout_ms) });
        if (budget_deadline) |limit| if (limit.compare(.lt, deadline)) {
            deadline = limit;
        };
        try self.validate(input, secret);
        try self.io.checkCancel();
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const argv = try self.wrap(a, input.argv);
        const policy = try std.mem.join(a, "\x00", argv[0 .. argv.len - input.argv.len]);
        var environment: std.process.Environ.Map = .init(allocator);
        defer environment.deinit();
        try environment.put("PATH", "/usr/bin:/bin");
        try environment.put("HOME", self.scratch.path);
        try environment.put("TMPDIR", self.scratch.path);
        try environment.put("LANG", "C.UTF-8");
        if (Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, deadline)) return error.TaskTimeout;
        try self.ctx.database.exec("BEGIN IMMEDIATE;");
        errdefer if (self.ctx.database.inTransaction()) self.ctx.database.exec("ROLLBACK;") catch {};
        if (try self.ctx.generation() != input.generation) return error.StaleGeneration;
        if (try self.ctx.database.number("SELECT count(*) FROM execution_runs WHERE state IN('started','attention');", &.{}) != 0) return error.ExecutionNeedsReview;
        if (action) |id| if (try self.ctx.database.number("SELECT count(*) FROM actions a JOIN model_requests r ON r.id=a.request_id JOIN tasks t ON t.id=r.task_id WHERE a.id=? AND a.phase='started' AND a.name='act' AND a.mutating=1 AND a.management=0 AND t.state='running';", &.{.{ .int = id }}) != 1) return error.InvalidExecutionAction;
        const hash = try self.ctx.putBlob(policy);
        try self.ctx.database.run("INSERT INTO execution_runs(generation,action_id,workspace,scratch,backend,policy,state) VALUES(?,?,?,?,?,?,'started');", &.{ .{ .int = input.generation }, if (action) |id| .{ .int = id } else .null, .{ .text = self.workspace.path }, .{ .text = self.scratch.path }, .{ .text = @tagName(self.backend) }, .{ .blob = &hash } });
        const id = try self.ctx.database.number("SELECT last_insert_rowid();", &.{});
        for (input.argv, 0..) |arg, index| try self.ctx.database.run("INSERT INTO execution_args VALUES(?,?,?);", &.{ .{ .int = id }, .{ .int = @intCast(index) }, .{ .text = arg } });
        try self.ctx.advanceGeneration();
        try self.ctx.database.exec("COMMIT;");
        return self.perform(allocator, input, argv, &environment, id, secret, started, deadline) catch |err| {
            self.ctx.database.run("UPDATE execution_runs SET state='attention',diagnostic=? WHERE id=?;", &.{ .{ .text = @errorName(err) }, .{ .int = id } }) catch return error.ExecutionJournalUnavailable;
            return error.ExecutionOutcomeUncertain;
        };
    }

    fn perform(self: *Execution, allocator: Allocator, _: Input, argv: []const []const u8, environment: *const std.process.Environ.Map, id: i64, secret: ?[]const u8, started: Io.Clock.Timestamp, deadline: Io.Clock.Timestamp) !Result {
        try self.checkRoots();
        if (Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, deadline)) return error.CommandTimeoutBeforeSpawn;
        var child = try std.process.spawn(self.io, .{ .argv = argv, .cwd = .{ .dir = self.workspace.handle }, .environ_map = environment, .pgid = 0, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
        defer process.terminate(&child, self.io);
        try self.ctx.database.run("UPDATE execution_runs SET pid=? WHERE id=?;", &.{ .{ .int = child.id.? }, .{ .int = id } });
        var captured = try process.capture(&child, allocator, self.io, deadline, self.output_bytes);
        defer captured.deinit(allocator);
        var redacted = false;
        repository.rejectSecret(secret, captured.stdout) catch {
            redacted = true;
        };
        repository.rejectSecret(secret, captured.stderr) catch {
            redacted = true;
        };
        const term_kind: []const u8 = switch (captured.term) {
            .exited => "exit",
            .signal => "signal",
            .stopped => "stopped",
            .unknown => "unknown",
        };
        const term_value: i64 = switch (captured.term) {
            .exited => |value| value,
            .signal, .stopped => |value| @intCast(@backingInt(value)),
            .unknown => |value| value,
        };
        const elapsed: u64 = @intCast(@max(0, started.durationTo(Io.Clock.Timestamp.now(self.io, .awake)).raw.toMilliseconds()));
        const out = if (redacted) "" else captured.stdout;
        const err = if (redacted) "" else captured.stderr;
        try self.ctx.database.exec("BEGIN IMMEDIATE;");
        errdefer self.ctx.database.exec("ROLLBACK;") catch {};
        const stdout_hash = try self.ctx.putBlob(out);
        const stderr_hash = try self.ctx.putBlob(err);
        const incomplete = captured.reason != .exited;
        try self.ctx.database.run("UPDATE execution_runs SET state='finished',reason=?,term_kind=?,term_value=?,stdout=?,stderr=?,incomplete=?,redacted=?,elapsed_ms=? WHERE id=? AND state='started';", &.{ .{ .text = @tagName(captured.reason) }, .{ .text = term_kind }, .{ .int = term_value }, .{ .blob = &stdout_hash }, .{ .blob = &stderr_hash }, .{ .int = @intFromBool(incomplete) }, .{ .int = @intFromBool(redacted) }, .{ .int = @intCast(elapsed) }, .{ .int = id } });
        try self.ctx.advanceGeneration();
        try self.ctx.database.exec("COMMIT;");
        if (captured.reason == .canceled) self.io.recancel();
        return .{ .id = id, .reason = captured.reason, .term_kind = term_kind, .term_value = term_value, .stdout_bytes = out.len, .stderr_bytes = err.len, .incomplete = incomplete, .redacted = redacted, .elapsed_ms = elapsed };
    }

    pub fn recoverAfterOwnerExit(self: *Execution) !void {
        try self.ctx.database.exec("BEGIN IMMEDIATE;");
        errdefer self.ctx.database.exec("ROLLBACK;") catch {};
        if (try self.ctx.database.number("SELECT count(*) FROM execution_runs WHERE state='started';", &.{}) != 0) {
            try self.ctx.database.exec("UPDATE execution_runs SET state='attention',diagnostic='OwnerExited' WHERE state='started';");
            try self.ctx.advanceGeneration();
        }
        try self.ctx.database.exec("COMMIT;");
    }

    /// Records trusted host review; never signals a historical PID or repeats a command.
    pub fn acknowledge(self: *Execution, id: i64) !void {
        try self.ctx.database.exec("BEGIN IMMEDIATE;");
        errdefer self.ctx.database.exec("ROLLBACK;") catch {};
        if (try self.ctx.database.number("SELECT count(*) FROM execution_runs WHERE id=? AND state='attention';", &.{.{ .int = id }}) != 1) return error.ExecutionNeedsReview;
        try self.ctx.database.run("UPDATE execution_runs SET state='reviewed' WHERE id=?;", &.{.{ .int = id }});
        try self.ctx.advanceGeneration();
        try self.ctx.database.exec("COMMIT;");
    }

    pub fn output(self: *Execution, allocator: Allocator, id: i64, stderr: bool) ![]u8 {
        var query = try self.ctx.database.statement(if (stderr) "SELECT stderr FROM execution_runs WHERE id=? AND state='finished';" else "SELECT stdout FROM execution_runs WHERE id=? AND state='finished';", &.{.{ .int = id }});
        defer query.deinit();
        if (!try query.step()) return error.OutputUnavailable;
        return self.ctx.readBlob(allocator, query.blob(0));
    }

    fn checkRoots(self: *Execution) !void {
        try checkDirectory(self.io, self.workspace);
        try checkDirectory(self.io, self.scratch_parent);
        try checkDirectory(self.io, self.scratch);
        try filesystem.requirePrivateDirectory(self.scratch_parent.handle, self.io);
        try filesystem.requirePrivateDirectory(self.scratch.handle, self.io);
        for (self.read_only) |grant| try checkDirectory(self.io, grant);
        try privateStore(self.ctx, self.io, null);
    }

    pub fn wrap(self: *Execution, allocator: Allocator, command: []const []const u8) ![]const []const u8 {
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(allocator, backendPath(self.backend));
        switch (self.backend) {
            .seatbelt => {
                var text: Io.Writer.Allocating = .init(allocator);
                try text.writer.writeAll("(version 1)(deny default)(allow process-exec process-fork)(allow signal (target same-sandbox))(allow file-read* file-test-existence (literal \"/\"))(allow file-read* file-map-executable");
                for (mac_reads) |path| try pathFilter(&text.writer, allocator, path);
                try pathFilter(&text.writer, allocator, self.workspace.path);
                try pathFilter(&text.writer, allocator, self.scratch.path);
                for (self.read_only) |grant| try pathFilter(&text.writer, allocator, grant.path);
                try text.writer.writeAll(")(allow file-write*");
                try pathFilter(&text.writer, allocator, self.scratch.path);
                try text.writer.writeAll(" (literal \"/dev/null\"))");
                try text.writer.writeAll("(allow file-read-metadata file-test-existence");
                for (mac_reads) |path| try ancestorFilter(&text.writer, allocator, path);
                try ancestorFilter(&text.writer, allocator, self.workspace.path);
                try ancestorFilter(&text.writer, allocator, self.scratch.path);
                for (self.read_only) |grant| try ancestorFilter(&text.writer, allocator, grant.path);
                try text.writer.writeAll(")");
                try args.appendSlice(allocator, &.{ "-p", try text.toOwnedSlice() });
            },
            .bubblewrap => {
                try args.appendSlice(allocator, &.{ "--unshare-user", "--unshare-pid", "--unshare-net", "--unshare-ipc", "--unshare-uts", "--die-with-parent", "--new-session", "--cap-drop", "ALL", "--clearenv", "--proc", "/proc", "--dev", "/dev" });
                for (linux_reads) |path| try args.appendSlice(allocator, &.{ "--ro-bind-try", path, path });
                for (self.read_only) |grant| try args.appendSlice(allocator, &.{ "--ro-bind", grant.path, grant.path });
                try args.appendSlice(allocator, &.{ "--ro-bind", self.workspace.path, self.workspace.path, "--bind", self.scratch.path, self.scratch.path, "--chdir", self.workspace.path, "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "HOME", self.scratch.path, "--setenv", "TMPDIR", self.scratch.path, "--setenv", "LANG", "C.UTF-8", "--" });
            },
        }
        try args.appendSlice(allocator, command);
        return args.toOwnedSlice(allocator);
    }
};

const mac_reads = [_][]const u8{ "/System/Library", "/usr/lib", "/usr/bin", "/bin", "/usr/share", "/dev/null", "/dev/urandom", "/dev/random", "/private/var/db/dyld", "/private/var/select/sh" };
const linux_reads = [_][]const u8{ "/usr/bin", "/usr/lib", "/usr/share", "/bin", "/lib", "/lib64" };

fn backendPath(backend: Backend) []const u8 {
    return if (backend == .seatbelt) "/usr/bin/sandbox-exec" else "/usr/bin/bwrap";
}

fn pathFilter(writer: *Io.Writer, allocator: Allocator, path: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, path, .{});
    try writer.print(" (subpath {s})", .{encoded});
}

fn ancestorFilter(writer: *Io.Writer, allocator: Allocator, path: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, path, .{});
    try writer.print(" (path-ancestors {s})", .{encoded});
}

fn covers(parent: []const u8, path: []const u8) bool {
    if (path.len < parent.len) return false;
    const prefix_matches = if (builtin.os.tag == .macos) std.ascii.eqlIgnoreCase(parent, path[0..parent.len]) else std.mem.eql(u8, parent, path[0..parent.len]);
    return prefix_matches and (path.len == parent.len or path[parent.len] == '/');
}

fn openDirectory(ctx: *context.Context, allocator: Allocator, io: Io, path: []const u8) !Directory {
    if (!std.fs.path.isAbsolute(path) or path.len <= 1 or !std.unicode.utf8ValidateSlice(path)) return error.InvalidExecutionRoot;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidExecutionRoot;
    const handle = try Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false, .iterate = true });
    errdefer handle.close(io);
    var physical: [Io.Dir.max_path_bytes]u8 = undefined;
    const len = try handle.realPath(io, &physical);
    if (!std.mem.eql(u8, physical[0..len], path)) return error.NonPhysicalRoot;
    try privateStore(ctx, io, path);
    return .{ .path = try allocator.dupe(u8, path), .handle = handle, .identity = try filesystem.identity(handle, io) };
}

fn checkDirectory(io: Io, directory: Directory) !void {
    const current = try Io.Dir.openDirAbsolute(io, directory.path, .{ .follow_symlinks = false, .iterate = true });
    defer current.close(io);
    const id = try filesystem.identity(current, io);
    if (!std.mem.eql(u8, id.text(), directory.identity.text())) return error.ExecutionRootChanged;
}

fn privateStore(ctx: *context.Context, io: Io, grant: ?[]const u8) !void {
    const path = ctx.database.filename();
    if (path.len == 0) return;
    if (grant) |root| if (covers(root, path)) return error.PrivateStateReachable;
    for (if (builtin.os.tag == .macos) &mac_reads else &linux_reads) |root| if (covers(root, path)) return error.PrivateStateReachable;
    var native_path: [Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= native_path.len) return error.InvalidExecutionRoot;
    @memcpy(native_path[0..path.len], path);
    native_path[path.len] = 0;
    const file = try filesystem.openRegular(.cwd(), io, native_path[0..path.len :0]);
    file.close(io);
}
