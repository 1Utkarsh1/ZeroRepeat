const std = @import("std");
const context = @import("context.zig");
const repository = @import("repository.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn rootPath(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    return a.dupe(u8, buffer[0..length]);
}

fn number(ctx: *context.Context, sql: [:0]const u8) !i64 {
    return ctx.database.number(sql, &.{});
}

fn replacement(ref: repository.Ref) repository.Edit {
    return .{ .path = "main.zig", .ref = ref, .replacements = &.{.{ .start = 0, .end = 3, .text = "new" }} };
}

test "native repository snapshots preserve exact bytes and stable versions without conflating external replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old 🐈\r\n" });
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    var first = try repo.read(a, "main.zig", null);
    defer first.deinit(a);
    const generation = try ctx.generation();
    var same = try repo.read(a, "main.zig", null);
    defer same.deinit(a);
    try std.testing.expectEqual(first.ref, same.ref);
    try std.testing.expectEqual(generation, try ctx.generation());
    try std.testing.expectEqualStrings("old 🐈\r\n", first.body);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "external same inode" });
    var changed = try repo.read(a, "main.zig", null);
    defer changed.deinit(a);
    try std.testing.expectEqual(first.ref.id, changed.ref.id);
    try std.testing.expectEqual(first.ref.version + 1, changed.ref.version);
    try tmp.dir.writeFile(io, .{ .sub_path = "other", .data = "replacement inode" });
    try tmp.dir.rename("other", tmp.dir, "main.zig", io);
    var recreated = try repo.read(a, "main.zig", null);
    defer recreated.deinit(a);
    try std.testing.expect(recreated.ref.id != first.ref.id);
    try std.testing.expectEqual(@as(i64, 1), recreated.ref.version);
}

test "expected-version native edit retains displaced inode and explicit undo is a fresh versioned edit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old 🐈\r\n" });
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    var before = try repo.read(a, "main.zig", null);
    defer before.deinit(a);
    const change: repository.ChangeSet = .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &.{replacement(before.ref)} };
    var preview = try repo.preview(a, change, null);
    defer preview.deinit(io);
    try std.testing.expectEqualStrings("new 🐈\r\n", preview.candidates[0].after);
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM edit_batches;"));
    const batch = try repo.apply(a, change, null);
    var after = try repo.read(a, "main.zig", null);
    defer after.deinit(a);
    try std.testing.expectEqual(before.ref.id, after.ref.id);
    try std.testing.expectEqual(before.ref.version + 1, after.ref.version);
    try std.testing.expectEqualStrings("new 🐈\r\n", after.body);
    var row = try ctx.database.prepare("SELECT recovery_name FROM edit_entries WHERE batch_id=1;");
    defer row.deinit();
    try std.testing.expect(try row.step());
    const saved = try tmp.dir.readFileAlloc(io, row.text(0), a, .limited(4096));
    defer a.free(saved);
    try std.testing.expectEqualStrings(before.body, saved);
    _ = try repo.undo(a, batch, try ctx.generation(), &.{after.ref}, null);
    var undone = try repo.read(a, "main.zig", null);
    defer undone.deinit(a);
    try std.testing.expectEqualStrings(before.body, undone.body);
    try std.testing.expectEqual(after.ref.version + 1, undone.ref.version);
    try std.testing.expectEqual(@as(i64, 2), try number(&ctx, "SELECT count(*) FROM edit_batches WHERE state='applied';"));
}

test "stale expected file bytes and unauthorized paths fail before intent or publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old" });
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    var before = try repo.read(a, "main.zig", null);
    defer before.deinit(a);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "user edit" });
    try std.testing.expectError(error.StaleFile, repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &.{replacement(before.ref)} }, null));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM edit_batches;"));
    try std.testing.expectError(error.PathDenied, repo.read(a, "ungranted.zig", null));
    for ([_][]const u8{ "../main.zig", "/main.zig", "a//b", "a/./b", "a/../b", "a\\b", "a\n" }) |path| try std.testing.expectError(error.InvalidRepositoryPath, repo.read(a, path, null));
    for ([_][]const u8{ ".git/config", "a/.GIT/config", ".zerorepeat/data", ".zerorepeat-edit-secret" }) |path| try std.testing.expectError(error.ReservedRepositoryPath, repo.read(a, path, null));
}

var failure_point: repository.FaultPoint = .after_exchange;
fn injectFailure(point: repository.FaultPoint, _: std.Io.Dir, _: [:0]const u8, _: [:0]const u8) !void {
    if (point == failure_point) return error.InjectedPublicationFault;
}

test "each native publication fault retains both file versions and blocks an automatic second batch" {
    for ([_]repository.FaultPoint{ .staged, .before_exchange, .after_exchange, .before_receipt }) |point| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try rootPath(&tmp);
        defer a.free(root);
        try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old" });
        var ctx = try context.Context.open(":memory:", .{});
        defer ctx.close();
        var repo = try repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
        defer repo.close();
        var before = try repo.read(a, "main.zig", null);
        defer before.deinit(a);
        failure_point = point;
        repository.fault_hook = injectFailure;
        defer repository.fault_hook = null;
        try std.testing.expectError(error.EditOutcomeUncertain, repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &.{replacement(before.ref)} }, null));
        const exchanged = point == .after_exchange or point == .before_receipt;
        const target = try tmp.dir.readFileAlloc(io, "main.zig", a, .limited(4096));
        defer a.free(target);
        try std.testing.expectEqualStrings(if (exchanged) "new" else "old", target);
        var row = try ctx.database.prepare("SELECT e.recovery_name,b.diagnostic FROM edit_entries e JOIN edit_batches b ON b.id=e.batch_id WHERE b.state='attention';");
        defer row.deinit();
        try std.testing.expect(try row.step());
        try std.testing.expectEqualStrings("InjectedPublicationFault", row.text(1));
        const retained = try tmp.dir.readFileAlloc(io, row.text(0), a, .limited(4096));
        defer a.free(retained);
        try std.testing.expectEqualStrings(if (exchanged) "old" else "new", retained);
        repository.fault_hook = null;
        var current = try repo.read(a, "main.zig", null);
        defer current.deinit(a);
        const edits = [_]repository.Edit{.{ .path = "main.zig", .ref = current.ref, .replacements = &.{.{ .start = 0, .end = 3, .text = "next" }} }};
        try std.testing.expectError(error.EditNeedsReview, repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &edits }, null));
        try repo.acknowledge(1);
        _ = try repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &edits }, null);
        try std.testing.expect(!ctx.database.inTransaction());
    }
}

fn concurrentWrite(point: repository.FaultPoint, dir: std.Io.Dir, name: [:0]const u8, _: [:0]const u8) !void {
    if (point == .before_exchange) try dir.writeFile(io, .{ .sub_path = name, .data = "concurrent user bytes" });
}

test "a writer racing the final check is detected and its displaced inode remains intact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old" });
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    var before = try repo.read(a, "main.zig", null);
    defer before.deinit(a);
    repository.fault_hook = concurrentWrite;
    defer repository.fault_hook = null;
    try std.testing.expectError(error.EditOutcomeUncertain, repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &.{replacement(before.ref)} }, null));
    var row = try ctx.database.prepare("SELECT e.recovery_name,b.diagnostic FROM edit_entries e JOIN edit_batches b ON b.id=e.batch_id;");
    defer row.deinit();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings("ConcurrentEditPreserved", row.text(1));
    const saved = try tmp.dir.readFileAlloc(io, row.text(0), a, .limited(4096));
    defer a.free(saved);
    try std.testing.expectEqualStrings("concurrent user bytes", saved);
    const target = try tmp.dir.readFileAlloc(io, "main.zig", a, .limited(4096));
    defer a.free(target);
    try std.testing.expectEqualStrings("new", target);
}

fn stopSecond(point: repository.FaultPoint, _: std.Io.Dir, name: [:0]const u8, _: [:0]const u8) !void {
    if (point == .before_exchange and std.mem.eql(u8, name, "second.zig")) return error.InjectedSecondFileFault;
}

test "multi-file preflight is all-or-none and partial publication remains journaled without replay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second.zig", .data = "two" });
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root, &.{ .{ .path = "main.zig", .write = true }, .{ .path = "second.zig", .write = true } });
    defer repo.close();
    var first = try repo.read(a, "main.zig", null);
    defer first.deinit(a);
    var second = try repo.read(a, "second.zig", null);
    defer second.deinit(a);
    const edits = [_]repository.Edit{ replacement(first.ref), .{ .path = "second.zig", .ref = second.ref, .replacements = &.{.{ .start = 0, .end = 3, .text = "TWO" }} } };
    try tmp.dir.writeFile(io, .{ .sub_path = "second.zig", .data = "changed" });
    try std.testing.expectError(error.StaleFile, repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &edits }, null));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM edit_batches;"));
    try tmp.dir.writeFile(io, .{ .sub_path = "second.zig", .data = "two" });
    repository.fault_hook = stopSecond;
    defer repository.fault_hook = null;
    try std.testing.expectError(error.EditOutcomeUncertain, repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &edits }, null));
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM edit_entries WHERE state='applied';"));
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM edit_entries WHERE state='started';"));
}

test "configured credentials cannot enter file snapshots or an assembled replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const key = "fixture-credential-123";
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = key });
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    try std.testing.expectError(error.SensitiveData, repo.read(a, "main.zig", key));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM repo_files;"));
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "fixture-" });
    var before = try repo.read(a, "main.zig", key);
    defer before.deinit(a);
    try std.testing.expectError(error.SensitiveData, repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &.{.{ .path = "main.zig", .ref = before.ref, .replacements = &.{.{ .start = 8, .end = 8, .text = "credential-123" }} }} }, key));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM blobs WHERE instr(CAST(body AS TEXT),'fixture-credential-123')>0;"));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM edit_batches;"));
}

test "root binding and component no-follow checks reject symlink and hardlink escapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old" });
    try tmp.dir.createDir(io, "inside", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "inside/file", .data = "inside" });
    try tmp.dir.symLink(io, "main.zig", "link.zig", .{});
    try tmp.dir.symLink(io, "inside", "linked", .{ .is_directory = true });
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root, &.{ .{ .path = "main.zig", .write = true }, .{ .path = "link.zig" }, .{ .path = "linked/file" } });
    defer repo.close();
    try std.testing.expectError(error.NotRegularFile, repo.read(a, "link.zig", null));
    if (repo.read(a, "linked/file", null)) |snapshot| {
        var owned = snapshot;
        owned.deinit(a);
        return error.SymlinkUnexpectedlyFollowed;
    } else |_| {}
    try tmp.dir.hardLink("main.zig", tmp.dir, "hard.zig", io, .{});
    try std.testing.expectError(error.NotSingleLinkFile, repo.read(a, "main.zig", null));
    const nested = try std.fmt.allocPrint(a, "{s}/inside", .{root});
    defer a.free(nested);
    try std.testing.expectError(error.RepositoryMismatch, repository.Repository.open(&ctx, a, io, nested, &.{.{ .path = "file" }}));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM repo_files;"));
}

test "native metadata copying preserves executable mode a user attribute and macOS ACL" {
    const native_os = @import("builtin").os.tag;
    const attribute = if (native_os == .macos) struct {
        extern "c" fn fsetxattr(c_int, [*:0]const u8, [*]const u8, usize, u32, c_int) c_int;
    } else struct {
        extern "c" fn fsetxattr(c_int, [*:0]const u8, [*]const u8, usize, c_int) c_int;
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const file = try tmp.dir.createFile(io, "main.zig", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "old", 0);
    try file.setPermissions(io, .fromMode(0o755));
    const status = if (native_os == .macos) attribute.fsetxattr(file.handle, "user.zerorepeat-test", "retained", 8, 0, 0) else attribute.fsetxattr(file.handle, "user.zerorepeat-test", "retained", 8, 0);
    try std.testing.expectEqual(@as(c_int, 0), status);
    if (native_os == .macos) {
        const path = try std.fmt.allocPrint(a, "{s}/main.zig", .{root});
        defer a.free(path);
        var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/chmod", "+a", "everyone allow read", path }, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit });
        defer child.kill(io);
        try std.testing.expect((try child.wait(io)).success());
    }
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    var before = try repo.read(a, "main.zig", null);
    defer before.deinit(a);
    _ = try repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &.{replacement(before.ref)} }, null);
    var after = try repo.read(a, "main.zig", null);
    defer after.deinit(a);
    try std.testing.expectEqualSlices(u8, &before.metadata_hash, &after.metadata_hash);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), after.meta.stat.permissions.toMode() & 0o777);
}

fn applyThroughTool(repo: *repository.Repository, allocator: std.mem.Allocator, ref: repository.Ref) !void {
    const tools = @import("context_tools.zig");
    const ref_text = try std.fmt.allocPrint(a, "f{d}:v{d}", .{ ref.id, ref.version });
    defer a.free(ref_text);
    const arguments = try std.json.Stringify.valueAlloc(a, .{ .op = "repo.apply", .scope = repo.scope, .generation = try repo.ctx.generation(), .edits = .{.{ .path = "main.zig", .ref = ref_text, .replacements = .{.{ .start = 0, .end = 3, .text = "new" }} }} }, .{});
    defer a.free(arguments);
    var prepared = try tools.prepareWithRepository(a, .{ .name = "patch", .arguments = arguments }, repo);
    defer prepared.deinit();
    var result = try prepared.applyGuarded(repo.ctx, allocator, null, null);
    defer result.deinit(allocator);
}

test "repository edit and acknowledgement allocation failures release memory and preserve uncertainty" {
    var maximum: usize = 0;
    var saw_uncertain = false;
    var saw_committed_ack_failure = false;
    var index: usize = 0;
    while (index == 0 or index <= maximum) : (index += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try rootPath(&tmp);
        defer a.free(root);
        try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old" });
        var ctx = try context.Context.open(":memory:", .{});
        defer ctx.close();
        var repo = try repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
        defer repo.close();
        var before = try repo.read(a, "main.zig", null);
        defer before.deinit(a);
        var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = if (index == 0) std.math.maxInt(usize) else index - 1, .resize_fail_index = 0 });
        const result = applyThroughTool(&repo, failing.allocator(), before.ref);
        if (index == 0) {
            try result;
            maximum = failing.alloc_index;
        } else if (result) |_| {} else |err| {
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed or err == error.CommittedResultUnavailable);
            if (err == error.CommittedResultUnavailable) {
                saw_uncertain = true;
                if (try number(&ctx, "SELECT count(*) FROM edit_batches WHERE state='applied';") == 1) saw_committed_ack_failure = true;
            }
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expect(!ctx.database.inTransaction());
    }
    try std.testing.expect(saw_uncertain);
    try std.testing.expect(saw_committed_ack_failure);
}

test "failed SQLite publication acknowledgement leaves the applied file and retained original for inspection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old" });
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root, &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    var base = try repo.read(a, "main.zig", null);
    defer base.deinit(a);
    try ctx.database.exec("CREATE TRIGGER fail_edit_receipt BEFORE UPDATE OF result_version ON edit_entries BEGIN SELECT RAISE(ABORT,'injected failure'); END;");
    try std.testing.expectError(error.EditOutcomeUncertain, repo.apply(a, .{ .scope = repo.scope, .generation = try ctx.generation(), .edits = &.{replacement(base.ref)} }, null));
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM edit_batches WHERE state='attention' AND diagnostic='SqliteConstraint';"));
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM edit_entries WHERE state='started';"));
    const target = try tmp.dir.readFileAlloc(io, "main.zig", a, .limited(16));
    defer a.free(target);
    try std.testing.expectEqualStrings("new", target);
    try std.testing.expect(!ctx.database.inTransaction());
}

test "version two migration preserves action evidence and assigns historical context-management classification" {
    const db = @import("db.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/legacy.sqlite", .{root}, 0);
    defer a.free(path);
    const original = "version-two-evidence-nonce";
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(original, &hash, .{});
    {
        var legacy = try db.Db.openUnconfigured(path);
        defer legacy.close();
        try legacy.exec(@embedFile("fixtures/context-v1.sql"));
        try legacy.exec(@embedFile("fixtures/task-v2.sql"));
        try legacy.run("INSERT INTO blobs VALUES(?,?);", &.{ .{ .blob = &hash }, .{ .blob = original } });
        try legacy.exec("INSERT INTO messages(id,external_id,role,kind,hash,tokens,tool_name,call_id,group_id,pinned) SELECT 1,'legacy',1,0,hash,1,'','','',0 FROM blobs; INSERT INTO tasks(id,state,max_requests,max_tool_calls,max_management_rounds,max_wire_bytes,max_output_tokens,output_per_request,max_elapsed_ms) VALUES(1,'failed',16,64,8,100000,1000,100,1000); INSERT INTO task_requirements VALUES(1,1); INSERT INTO model_requests(id,task_id,generation,payload,output_reserved,phase) SELECT 1,1,17,hash,100,'replied' FROM blobs; INSERT INTO actions(request_id,position,provider_id,name,arguments,mutating,phase) SELECT 1,0,'old-act','act',hash,1,'succeeded' FROM blobs; INSERT INTO actions(request_id,position,provider_id,name,arguments,mutating,phase) SELECT 1,1,'old-inspect','inspect',hash,0,'failed' FROM blobs; UPDATE meta SET value=17 WHERE key='generation'; PRAGMA application_id=0x5a525054; PRAGMA user_version=2;");
    }
    var ctx = try context.Context.open(path, .{});
    defer ctx.close();
    try std.testing.expectEqual(@as(i64, 3), try number(&ctx, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 17), try ctx.generation());
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT management FROM actions WHERE provider_id='old-act';"));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT management FROM actions WHERE provider_id='old-inspect';"));
    const bytes = try ctx.readBlob(a, &hash);
    defer a.free(bytes);
    try std.testing.expectEqualStrings(original, bytes);
    try std.testing.expectError(error.SqliteConstraint, ctx.database.exec("UPDATE actions SET management=0 WHERE provider_id='old-act';"));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM pragma_foreign_key_check;"));
}

test "repository capabilities cannot expose their own SQLite store or sidecars" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/private.sqlite", .{root}, 0);
    defer a.free(path);
    var ctx = try context.Context.open(path, .{});
    defer ctx.close();
    for ([_][]const u8{ "private.sqlite", "private.sqlite-wal", "private.sqlite-shm", "private.sqlite-journal", "PRIVATE.SQLITE-WAL" }) |file| try std.testing.expectError(error.ReservedRepositoryPath, repository.Repository.open(&ctx, a, io, root, &.{.{ .path = file, .write = true }}));
    try std.testing.expectError(error.ReservedRepositoryPath, repository.Repository.open(&ctx, a, io, "/", &.{.{ .path = path[1..], .write = true }}));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM repositories;"));
}

test "bounded replacements reject overlap split UTF8 and preserve untouched newline bytes" {
    const before = "a🐈\r\nb";
    const after = try repository.replace(a, before, &.{ .{ .start = 1, .end = 5, .text = "dog" }, .{ .start = 7, .end = 8, .text = "B" } });
    defer a.free(after);
    try std.testing.expectEqualStrings("adog\r\nB", after);
    for ([_][]const repository.Replacement{
        &.{.{ .start = 2, .end = 5, .text = "x" }},
        &.{ .{ .start = 0, .end = 4, .text = "x" }, .{ .start = 1, .end = 5, .text = "y" } },
        &.{.{ .start = 9, .end = 10, .text = "x" }},
        &.{.{ .start = 5, .end = 1, .text = "x" }},
        &.{ .{ .start = 0, .end = 0, .text = "x" }, .{ .start = 0, .end = 0, .text = "y" } },
    }) |changes| try std.testing.expectError(error.InvalidReplacement, repository.replace(a, before, changes));
}
