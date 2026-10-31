const std = @import("std");
const builtin = @import("builtin");
const context = @import("context.zig");
const execution = @import("execution.zig");
const a = std.testing.allocator;
const io = std.testing.io;

test "data-volume aliases remain denied by the actual macOS sandbox" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var roots = try Roots.init();
    defer roots.deinit();
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    try roots.tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "alias-private-nonce" });
    const parent = std.fs.path.dirname(roots.workspace).?;
    const alias = try std.fmt.allocPrint(a, "/System/Volumes/Data{s}/outside", .{parent});
    defer a.free(alias);
    const result = try exec.run(a, .{ .generation = try ctx.generation(), .argv = &.{ "/bin/sh", "-c", "if /bin/cat \"$1\"; then exit 91; fi", "alias-probe", alias }, .timeout_ms = 2000 }, null, null, null);
    try std.testing.expectEqual(@as(i64, 0), result.term_value);
    const stdout = try exec.output(a, result.id, false);
    defer a.free(stdout);
    try std.testing.expectEqual(@as(usize, 0), stdout.len);
}

test "deadline cleanup terminates a TERM-ignoring parent and its ordinary descendant group" {
    var roots = try Roots.init();
    defer roots.deinit();
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    const program = "trap '' TERM; (/bin/sleep 0.2; printf alive > \"$TMPDIR/descendant\") & wait";
    const control = try shell(&exec, program, 2000, null);
    try std.testing.expectEqual(@as(i64, 0), control.term_value);
    try roots.tmp.dir.deleteFile(io, "scratch/descendant");
    const terminated = try shell(&exec, program, 50, null);
    try std.testing.expectEqual(execution.process.Reason.timed_out, terminated.reason);
    try io.sleep(.fromMilliseconds(300), .awake);
    try std.testing.expectError(error.FileNotFound, roots.tmp.dir.openFile(io, "scratch/descendant", .{}));
}

test "external cancellation publishes a known canceled result and kills its owned process group" {
    var roots = try Roots.init();
    defer roots.deinit();
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    var running = try io.concurrent(execution.Execution.run, .{ &exec, a, execution.Input{ .generation = try ctx.generation(), .argv = &.{ "/bin/sh", "-c", "trap '' TERM; while :; do :; done" }, .timeout_ms = 2000 }, @as(?[]const u8, null), @as(?i64, null), @as(?std.Io.Clock.Timestamp, null) });
    defer _ = running.cancel(io) catch {};
    const deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .clock = .awake, .raw = .fromSeconds(1) });
    while (try ctx.database.number("SELECT count(*) FROM execution_runs WHERE pid IS NOT NULL;", &.{}) == 0) {
        if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return error.ProcessDidNotStart;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const result = try running.cancel(io);
    try std.testing.expectEqual(execution.process.Reason.canceled, result.reason);
    try std.testing.expect(result.incomplete);
    try std.testing.expectEqual(@as(i64, 1), try ctx.database.number("SELECT count(*) FROM execution_runs WHERE state='finished' AND reason='canceled';", &.{}));
}

test "schema three migration preserves repository evidence and refuses incomplete schema four" {
    const sqlite = @import("db.zig");
    var roots = try Roots.init();
    defer roots.deinit();
    const parent = std.fs.path.dirname(roots.workspace).?;
    const path = try std.fmt.allocPrintSentinel(a, "{s}/legacy.sqlite", .{parent}, 0);
    defer a.free(path);
    const original = "retained-schema-three-source";
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(original, &hash, .{});
    {
        var old = try sqlite.Db.openUnconfigured(path);
        defer old.close();
        try old.exec(@embedFile("fixtures/repository-v3.sql"));
        try old.run("INSERT INTO blobs VALUES(?,?);", &.{ .{ .blob = &hash }, .{ .blob = original } });
        try old.exec("INSERT INTO repo_files VALUES(1,'source','fixture',1,1); UPDATE meta SET value=17 WHERE key='generation';");
        try old.run("INSERT INTO repo_versions VALUES(1,1,?,420,'fixture',?);", &.{ .{ .blob = &hash }, .{ .blob = &hash } });
    }
    {
        var ctx = try context.Context.open(path, .{});
        defer ctx.close();
        try std.testing.expectEqual(@as(i64, 4), try ctx.database.number("PRAGMA user_version;", &.{}));
        try std.testing.expectEqual(@as(i64, 17), try ctx.generation());
        try std.testing.expectEqual(@as(i64, 1), try ctx.database.number("SELECT count(*) FROM repo_versions;", &.{}));
        const source = try ctx.readBlob(a, &hash);
        defer a.free(source);
        try std.testing.expectEqualStrings(original, source);
        try ctx.database.exec("DROP TABLE execution_args;");
    }
    try std.testing.expectError(error.IncompleteSchema, context.Context.open(path, .{}));
}

test "private SQLite roots and nonphysical directory paths are refused before command intent" {
    var roots = try Roots.init();
    defer roots.deinit();
    const path = try std.fmt.allocPrintSentinel(a, "{s}/private.sqlite", .{roots.workspace}, 0);
    defer a.free(path);
    var ctx = try context.Context.open(path, .{});
    defer ctx.close();
    try std.testing.expectError(error.PrivateStateReachable, roots.open(&ctx));
    var memory = try context.Context.open(":memory:", .{});
    defer memory.close();
    const nonphysical = try std.fmt.allocPrint(a, "{s}/.", .{roots.workspace});
    defer a.free(nonphysical);
    try std.testing.expectError(error.NonPhysicalRoot, execution.Execution.open(&memory, a, io, .{ .workspace = nonphysical, .scratch = roots.scratch }));
    try std.testing.expectError(error.InvalidExecutionRoot, execution.Execution.open(&memory, a, io, .{ .workspace = "/", .scratch = roots.scratch }));
}

test "execution and final tool acknowledgement allocation failures preserve uncertainty without leaking" {
    var maximum: usize = 0;
    var index: usize = 0;
    var saw_uncertain = false;
    var saw_finished = false;
    while (index <= maximum) : (index += 1) {
        var roots = try Roots.init();
        defer roots.deinit();
        var ctx = try context.Context.open(":memory:", .{});
        defer ctx.close();
        var exec = try roots.open(&ctx);
        defer exec.close();
        const arguments = try std.json.Stringify.valueAlloc(a, .{ .op = "exec.run", .scope = exec.scope, .generation = try ctx.generation(), .argv = [_][]const u8{ "/bin/sh", "-c", "printf allocation-evidence" }, .timeout_ms = 1000 }, .{});
        defer a.free(arguments);
        var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = if (index == 0) std.math.maxInt(usize) else index - 1, .resize_fail_index = 0 });
        const result = applyThroughTool(&exec, failing.allocator(), arguments);
        if (index == 0) {
            try result;
            maximum = failing.alloc_index;
        } else if (result) |_| {} else |err| {
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed or err == error.CommittedResultUnavailable);
            if (err == error.CommittedResultUnavailable) {
                saw_uncertain = true;
                if (try ctx.database.number("SELECT count(*) FROM execution_runs WHERE state='finished';", &.{}) == 1) saw_finished = true;
            }
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expect(!ctx.database.inTransaction());
    }
    try std.testing.expect(saw_uncertain and saw_finished);
}

fn applyThroughTool(exec: *execution.Execution, allocator: std.mem.Allocator, arguments: []const u8) !void {
    var prepared = try @import("context_tools.zig").prepareWithCapabilities(allocator, .{ .name = "act", .arguments = arguments }, null, exec);
    defer prepared.deinit();
    var result = try prepared.applyGuarded(exec.ctx, allocator, null, null);
    defer result.deinit(allocator);
}

test "nested sandbox invocation cannot broaden the inherited filesystem capability" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var roots = try Roots.init();
    defer roots.deinit();
    try roots.tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "nested-private-nonce" });
    const outside = try std.fmt.allocPrint(a, "{s}/outside", .{std.fs.path.dirname(roots.workspace).?});
    defer a.free(outside);
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    const result = try exec.run(a, .{ .generation = try ctx.generation(), .argv = &.{ "/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/bin/cat", outside }, .timeout_ms = 1000 }, null, null, null);
    try std.testing.expect(result.term_value != 0);
    const stdout = try exec.output(a, result.id, false);
    defer a.free(stdout);
    try std.testing.expectEqual(@as(usize, 0), stdout.len);
}

test "bounded execution previews retain exact tail evidence for scoped paged retrieval" {
    const tools = @import("context_tools.zig");
    var roots = try Roots.init();
    defer roots.deinit();
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    const command = try std.json.Stringify.valueAlloc(a, .{ .op = "exec.run", .scope = exec.scope, .generation = try ctx.generation(), .argv = [_][]const u8{ "/bin/sh", "-c", "printf '%01000d' 0; printf tail-evidence-nonce" }, .timeout_ms = 1000 }, .{});
    defer a.free(command);
    var prepared = try tools.prepareWithCapabilities(a, .{ .name = "act", .arguments = command }, null, &exec);
    defer prepared.deinit();
    var preview = try prepared.apply(&ctx, a);
    defer preview.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, preview.text, "tail-evidence-nonce") == null);
    try std.testing.expect(std.mem.indexOf(u8, preview.text, "\"has_more\":true") != null);
    const query = try std.json.Stringify.valueAlloc(a, .{ .op = "exec.read", .scope = exec.scope, .id = 1, .channel = "stdout", .offset = 1000, .limit = 100 }, .{});
    defer a.free(query);
    var retrieval = try tools.prepareWithCapabilities(a, .{ .name = "inspect", .arguments = query }, null, &exec);
    defer retrieval.deinit();
    var result = try retrieval.apply(&ctx, a);
    defer result.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "tail-evidence-nonce") != null);
}

pub const Roots = struct {
    tmp: std.testing.TmpDir,
    workspace: []u8,
    scratch: []u8,

    pub fn init() !Roots {
        if (builtin.os.tag == .linux) std.Io.Dir.cwd().access(io, "/usr/bin/bwrap", .{ .execute = true }) catch return error.SkipZigTest;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "workspace", .default_dir);
        try tmp.dir.createDir(io, "scratch", .default_dir);
        var bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &bytes);
        const workspace = try std.fmt.allocPrint(a, "{s}/workspace", .{bytes[0..len]});
        errdefer a.free(workspace);
        return .{ .tmp = tmp, .workspace = workspace, .scratch = try std.fmt.allocPrint(a, "{s}/scratch", .{bytes[0..len]}) };
    }

    pub fn deinit(self: *Roots) void {
        a.free(self.workspace);
        a.free(self.scratch);
        self.tmp.cleanup();
    }

    pub fn open(self: *Roots, ctx: *context.Context) !execution.Execution {
        return execution.Execution.open(ctx, a, io, .{ .workspace = self.workspace, .scratch = self.scratch, .timeout_ms = 2000, .output_bytes = 4096 });
    }
};

fn output(ctx: *context.Context, id: i64, stderr: bool) ![]u8 {
    var query = try ctx.database.statement(if (stderr) "SELECT stderr FROM execution_runs WHERE id=?;" else "SELECT stdout FROM execution_runs WHERE id=?;", &.{.{ .int = id }});
    defer query.deinit();
    try std.testing.expect(try query.step());
    return ctx.readBlob(a, query.blob(0));
}

fn shell(exec: *execution.Execution, text: []const u8, milliseconds: u32, secret: ?[]const u8) !execution.Result {
    return exec.run(a, .{ .generation = try exec.ctx.generation(), .argv = &.{ "/bin/sh", "-c", text }, .timeout_ms = milliseconds }, secret, null, null);
}

test "isolated native execution stores exact stdout stderr exit metadata and immutable command intent" {
    var roots = try Roots.init();
    defer roots.deinit();
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    const result = try shell(&exec, "printf 'first\\nlast'; printf 'diagnostic' >&2; exit 7", 2000, null);
    try std.testing.expectEqualStrings("exit", result.term_kind);
    try std.testing.expectEqual(@as(i64, 7), result.term_value);
    try std.testing.expectEqual(execution.process.Reason.exited, result.reason);
    const stdout = try output(&ctx, result.id, false);
    defer a.free(stdout);
    const stderr = try output(&ctx, result.id, true);
    defer a.free(stderr);
    try std.testing.expectEqualStrings("first\nlast", stdout);
    try std.testing.expectEqualStrings("diagnostic", stderr);
    try std.testing.expectEqual(@as(i64, 2), try ctx.generation());
    try std.testing.expectError(error.SqliteConstraint, ctx.database.exec("UPDATE execution_args SET value='replacement';"));
    try std.testing.expectError(error.SqliteConstraint, ctx.database.exec("UPDATE execution_runs SET term_value=0;"));
}

test "both output pressure and closed-pipe TERM-ignoring commands terminate under an absolute deadline" {
    var roots = try Roots.init();
    defer roots.deinit();
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    const full = try shell(&exec, "while :; do printf 012345678901234567890123456789; printf 012345678901234567890123456789 >&2; done", 1000, null);
    try std.testing.expectEqual(execution.process.Reason.output_limit, full.reason);
    try std.testing.expect(full.incomplete and full.stdout_bytes <= 4096 and full.stderr_bytes <= 4096);
    const closed = try shell(&exec, "exec 1>&- 2>&-; trap '' TERM; while :; do :; done", 50, null);
    try std.testing.expectEqual(execution.process.Reason.timed_out, closed.reason);
    try std.testing.expect(closed.elapsed_ms < 1500);
}

test "OS sandbox allows scratch but denies workspace mutations outside reads and symlink aliases" {
    var roots = try Roots.init();
    defer roots.deinit();
    try roots.tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "outside-private-nonce" });
    try roots.tmp.dir.writeFile(io, .{ .sub_path = "workspace/source", .data = "source-nonce" });
    try roots.tmp.dir.symLink(io, "../outside", "workspace/alias", .{});
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    const result = try shell(&exec, "cat source; printf scratch > \"$TMPDIR/allowed\"; if cat ../outside; then exit 91; fi; if cat alias; then exit 92; fi; if printf replaced > source; then exit 93; fi", 2000, null);
    try std.testing.expectEqual(@as(i64, 0), result.term_value);
    const stdout = try output(&ctx, result.id, false);
    defer a.free(stdout);
    try std.testing.expectEqualStrings("source-nonce", stdout);
    const original = try roots.tmp.dir.readFileAlloc(io, "workspace/source", a, .limited(100));
    defer a.free(original);
    try std.testing.expectEqualStrings("source-nonce", original);
    const scratch = try roots.tmp.dir.readFileAlloc(io, "scratch/allowed", a, .limited(100));
    defer a.free(scratch);
    try std.testing.expectEqualStrings("scratch", scratch);
}

test "clean child environment and configured credential redaction precede durable output publication" {
    var roots = try Roots.init();
    defer roots.deinit();
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    const clean = try shell(&exec, "/usr/bin/env", 2000, null);
    const environment = try output(&ctx, clean.id, false);
    defer a.free(environment);
    try std.testing.expect(std.mem.indexOf(u8, environment, "PATH=/usr/bin:/bin") != null);
    var entries = std.mem.splitScalar(u8, environment, '\n');
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const end = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidEnvironment;
        const key = entry[0..end];
        for ([_][]const u8{ "PATH", "HOME", "TMPDIR", "LANG", "PWD", "SHLVL", "_" }) |allowed| {
            if (std.mem.eql(u8, key, allowed)) break;
        } else return error.InheritedEnvironment;
    }
    try roots.tmp.dir.writeFile(io, .{ .sub_path = "workspace/key", .data = "fixture-key-for-execution" });
    const redacted = try shell(&exec, "cat key", 2000, "fixture-key-for-execution");
    try std.testing.expect(redacted.redacted);
    try std.testing.expectEqual(@as(usize, 0), redacted.stdout_bytes);
    try std.testing.expectEqual(@as(i64, 0), try ctx.database.number("SELECT count(*) FROM blobs WHERE instr(CAST(body AS TEXT),'fixture-key-for-execution')>0;", &.{}));
    try std.testing.expectError(error.SensitiveData, shell(&exec, "printf fixture-key-for-execution", 2000, "fixture-key-for-execution"));
}

test "post-spawn receipt failure requires host review and never repeats the command" {
    var roots = try Roots.init();
    defer roots.deinit();
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    try ctx.database.exec("CREATE TRIGGER fail_exec_result BEFORE UPDATE OF stdout ON execution_runs BEGIN SELECT RAISE(ABORT,'fixture'); END;");
    try std.testing.expectError(error.ExecutionOutcomeUncertain, shell(&exec, "printf once >> \"$TMPDIR/counter\"", 2000, null));
    try std.testing.expectError(error.ExecutionNeedsReview, shell(&exec, "printf twice >> \"$TMPDIR/counter\"", 2000, null));
    const counter = try roots.tmp.dir.readFileAlloc(io, "scratch/counter", a, .limited(100));
    defer a.free(counter);
    try std.testing.expectEqualStrings("once", counter);
    try exec.recoverAfterOwnerExit();
    try exec.acknowledge(1);
    try std.testing.expectEqual(@as(i64, 1), try ctx.database.number("SELECT count(*) FROM execution_runs WHERE state='reviewed';", &.{}));
}

test "execution refuses overlapping roots private state nonphysical roots and unsupported isolation" {
    var roots = try Roots.init();
    defer roots.deinit();
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    try std.testing.expectError(error.OverlappingExecutionRoots, execution.Execution.open(&ctx, a, io, .{ .workspace = roots.workspace, .scratch = roots.workspace }));
    try std.testing.expectError(error.IsolationUnavailable, execution.Execution.open(&ctx, a, io, .{ .workspace = roots.workspace, .scratch = roots.scratch, .backend = if (builtin.os.tag == .macos) .bubblewrap else .seatbelt }));
    var exec = try roots.open(&ctx);
    defer exec.close();
    try std.testing.expectError(error.AbsoluteExecutableRequired, exec.run(a, .{ .generation = 0, .argv = &.{"sh"}, .timeout_ms = 1000 }, null, null, null));
    try std.testing.expectError(error.StaleGeneration, exec.run(a, .{ .generation = 77, .argv = &.{"/bin/true"}, .timeout_ms = 1000 }, null, null, null));
    try std.testing.expectEqual(@as(i64, 0), try ctx.database.number("SELECT count(*) FROM execution_runs;", &.{}));
}
