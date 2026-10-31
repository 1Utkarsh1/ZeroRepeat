const std = @import("std");
const builtin = @import("builtin");
const root_module = @import("root");
const context = @import("context.zig");
const fs = @import("repository_fs.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_file_bytes = 1024 * 1024;
pub const max_edits = 8;
pub const max_replacements = 32;

pub const Access = struct { path: []const u8, write: bool = false };
pub const Ref = struct {
    id: i64,
    version: i64,

    pub fn parse(text: []const u8) !Ref {
        if (text.len < 5 or text[0] != 'f') return error.InvalidFileReference;
        var parts = std.mem.splitSequence(u8, text[1..], ":v");
        const id = parts.next().?;
        const version = parts.next() orelse return error.InvalidFileReference;
        if (parts.next() != null or id.len == 0 or version.len == 0) return error.InvalidFileReference;
        for (id) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidFileReference;
        for (version) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidFileReference;
        const result: Ref = .{ .id = std.fmt.parseInt(i64, id, 10) catch return error.InvalidFileReference, .version = std.fmt.parseInt(i64, version, 10) catch return error.InvalidFileReference };
        if (result.id <= 0 or result.version <= 0) return error.InvalidFileReference;
        return result;
    }
};
pub const Replacement = struct { start: usize, end: usize, text: []const u8 };
pub const Edit = struct { path: []const u8, ref: Ref, replacements: []const Replacement };
pub const ChangeSet = struct { scope: []const u8, generation: i64, edits: []const Edit, undo_of: ?i64 = null, action_id: ?i64 = null };
pub const Snapshot = struct {
    ref: Ref,
    body: []u8,
    hash: [32]u8,
    meta: fs.Metadata,
    metadata_hash: [32]u8,

    pub fn deinit(self: *Snapshot, allocator: Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

const Parent = struct {
    dir: Io.Dir,
    name: [:0]const u8,
    identity: fs.Identity,
};
const Candidate = struct { edit: Edit, parent: Parent, before: Snapshot, after: []const u8, after_hash: [32]u8, recovery: [:0]const u8 };
pub const Preview = struct {
    arena: std.heap.ArenaAllocator,
    candidates: []const Candidate,

    pub fn deinit(self: *Preview, io: Io) void {
        for (self.candidates) |item| item.parent.dir.close(io);
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const FaultPoint = enum { staged, before_exchange, after_exchange, before_receipt };
const faults_enabled = builtin.is_test or (if (@hasDecl(root_module, "repository_fault_injection")) root_module.repository_fault_injection else false);
// Fault injection is absent from normal runtime builds.
pub var fault_hook: if (faults_enabled) ?*const fn (FaultPoint, Io.Dir, [:0]const u8, [:0]const u8) anyerror!void else void = if (faults_enabled) null else {};

pub const Repository = struct {
    ctx: *context.Context,
    io: Io,
    arena: std.heap.ArenaAllocator,
    root: Io.Dir,
    root_path: []const u8,
    root_identity: fs.Identity,
    scope: []const u8,
    access: []const Access,
    store_path: ?[]const u8,
    store_identity: ?fs.Identity,

    /// Grants exact file paths; this capability boundary is not an OS sandbox.
    pub fn open(ctx: *context.Context, allocator: Allocator, io: Io, absolute_root: []const u8, access: []const Access) !Repository {
        if (!std.fs.path.isAbsolute(absolute_root) or access.len == 0 or access.len > 4096) return error.InvalidRepository;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const grants = try a.alloc(Access, access.len);
        for (access, grants, 0..) |grant, *owned, index| {
            try validatePath(grant.path);
            for (access[0..index]) |other| if (std.mem.eql(u8, grant.path, other.path)) return error.DuplicatePath;
            owned.* = .{ .path = try a.dupe(u8, grant.path), .write = grant.write };
        }
        const root = try Io.Dir.openDirAbsolute(io, absolute_root, .{ .follow_symlinks = false, .iterate = true });
        errdefer root.close(io);
        var physical: [Io.Dir.max_path_bytes]u8 = undefined;
        const length = try root.realPath(io, &physical);
        if (!std.mem.eql(u8, physical[0..length], absolute_root)) return error.NonPhysicalRoot;
        const root_id = try fs.identity(root, io);
        const path = try a.dupe(u8, absolute_root);
        var store_path: ?[]const u8 = null;
        var store_identity: ?fs.Identity = null;
        const database_file = ctx.database.filename();
        if (database_file.len > 0) {
            store_path = try Io.Dir.cwd().realPathFileAlloc(io, database_file, a);
            const name = try a.dupeSentinel(u8, store_path.?, 0);
            const file = try fs.openRegular(.cwd(), io, name);
            defer file.close(io);
            store_identity = (try fs.metadata(file, io)).identity;
            for (grants) |grant| if (privateStorePath(path, store_path.?, grant.path)) return error.ReservedRepositoryPath;
        }
        var session = try ctx.database.prepare("SELECT identity FROM identity WHERE id=1;");
        defer session.deinit();
        if (!try session.step()) return error.CorruptContent;
        const scope = try a.dupe(u8, session.text(0));
        try ctx.database.exec("BEGIN IMMEDIATE;");
        errdefer ctx.database.exec("ROLLBACK;") catch {};
        try ctx.database.run("INSERT OR IGNORE INTO repositories VALUES(1,?,?);", &.{ .{ .text = path }, .{ .text = root_id.text() } });
        if (try ctx.database.number("SELECT count(*) FROM repositories WHERE id=1 AND root=? AND identity=?;", &.{ .{ .text = path }, .{ .text = root_id.text() } }) != 1) return error.RepositoryMismatch;
        try ctx.database.exec("COMMIT;");
        return .{ .ctx = ctx, .io = io, .arena = arena, .root = root, .root_path = path, .root_identity = root_id, .scope = scope, .access = grants, .store_path = store_path, .store_identity = store_identity };
    }

    pub fn close(self: *Repository) void {
        self.root.close(self.io);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn authorize(self: *const Repository, path: []const u8, write: bool) !void {
        try validatePath(path);
        if (self.store_path) |store| if (privateStorePath(self.root_path, store, path)) return error.ReservedRepositoryPath;
        for (self.access) |grant| if (std.mem.eql(u8, grant.path, path)) {
            if (write and !grant.write) return error.WriteDenied;
            return;
        };
        return error.PathDenied;
    }

    pub fn hasWriteAccess(self: *const Repository) bool {
        for (self.access) |grant| if (grant.write) return true;
        return false;
    }

    fn parent(self: *Repository, allocator: Allocator, path: []const u8) !Parent {
        try self.checkRoot();
        var current = try self.root.openDir(self.io, ".", .{ .follow_symlinks = false, .iterate = true });
        errdefer current.close(self.io);
        var parts = std.mem.splitScalar(u8, path, '/');
        var name = parts.next().?;
        while (parts.next()) |next| {
            const opened = try current.openDir(self.io, name, .{ .follow_symlinks = false, .iterate = true });
            current.close(self.io);
            current = opened;
            name = next;
        }
        return .{ .dir = current, .name = try allocator.dupeSentinel(u8, name, 0), .identity = try fs.identity(current, self.io) };
    }

    fn checkRoot(self: *Repository) !void {
        var path: [Io.Dir.max_path_bytes]u8 = undefined;
        const size = try self.root.realPath(self.io, &path);
        const id = try fs.identity(self.root, self.io);
        if (!std.mem.eql(u8, self.root_path, path[0..size]) or !std.mem.eql(u8, id.text(), self.root_identity.text())) return error.RepositoryMoved;
    }

    fn readCurrent(self: *Repository, allocator: Allocator, parent_dir: Parent) !Snapshot {
        const file = try fs.openRegular(parent_dir.dir, self.io, parent_dir.name);
        defer file.close(self.io);
        if (self.store_identity) |store| {
            const observed = try fs.metadata(file, self.io);
            if (std.mem.eql(u8, store.text(), observed.identity.text())) return error.ReservedRepositoryPath;
        }
        const data = try fs.read(allocator, self.io, file, max_file_bytes);
        errdefer allocator.free(data.body);
        const metadata_hash = try fs.signature(allocator, self.io, file);
        if (!fs.same(data.meta, try fs.metadata(file, self.io))) return error.FileChanged;
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(data.body, &hash, .{});
        return .{ .ref = .{ .id = 0, .version = 0 }, .body = data.body, .hash = hash, .meta = data.meta, .metadata_hash = metadata_hash };
    }

    pub fn read(self: *Repository, allocator: Allocator, path: []const u8, secret: ?[]const u8) !Snapshot {
        try self.authorize(path, false);
        const dir = try self.parent(allocator, path);
        defer allocator.free(dir.name);
        defer dir.dir.close(self.io);
        var result = try self.readCurrent(allocator, dir);
        errdefer result.deinit(allocator);
        try rejectSecret(secret, result.body);
        try self.ctx.database.exec("BEGIN IMMEDIATE;");
        errdefer self.ctx.database.exec("ROLLBACK;") catch {};
        var active = try self.ctx.database.statement("SELECT f.id,f.version,f.identity,v.hash,v.permissions,v.metadata FROM repo_files f JOIN repo_versions v ON v.file_id=f.id AND v.version=f.version WHERE f.path=? AND f.active=1;", &.{.{ .text = path }});
        defer active.deinit();
        var existing = false;
        if (try active.step()) {
            if (std.mem.eql(u8, active.text(2), result.meta.identity.text())) {
                result.ref = .{ .id = active.int(0), .version = active.int(1) };
                existing = std.mem.eql(u8, active.blob(3), &result.hash) and active.int(4) == result.meta.stat.permissions.toMode() and std.mem.eql(u8, active.blob(5), &result.metadata_hash);
            }
        }
        if (!existing) {
            _ = try self.ctx.putBlob(result.body);
            if (result.ref.id == 0) {
                try self.ctx.database.run("UPDATE repo_files SET active=0 WHERE path=? AND active=1;", &.{.{ .text = path }});
                try self.ctx.database.run("INSERT INTO repo_files(path,identity,version,active) VALUES(?,?,1,1);", &.{ .{ .text = path }, .{ .text = result.meta.identity.text() } });
                result.ref = .{ .id = try self.ctx.database.number("SELECT last_insert_rowid();", &.{}), .version = 1 };
            } else {
                if (result.ref.version == std.math.maxInt(i64)) return error.VersionOverflow;
                result.ref.version += 1;
                try self.ctx.database.run("UPDATE repo_files SET version=? WHERE id=?;", &.{ .{ .int = result.ref.version }, .{ .int = result.ref.id } });
            }
            try self.insertVersion(result.ref, result.hash, result.meta, result.metadata_hash);
            try self.ctx.advanceGeneration();
        }
        try self.ctx.database.exec("COMMIT;");
        return result;
    }

    fn insertVersion(self: *Repository, ref: Ref, hash: [32]u8, meta: fs.Metadata, metadata_hash: [32]u8) !void {
        try self.ctx.database.run("INSERT INTO repo_versions VALUES(?,?,?,?,?,?);", &.{ .{ .int = ref.id }, .{ .int = ref.version }, .{ .blob = &hash }, .{ .int = meta.stat.permissions.toMode() }, .{ .text = meta.identity.text() }, .{ .blob = &metadata_hash } });
    }

    pub fn preview(self: *Repository, allocator: Allocator, change: ChangeSet, secret: ?[]const u8) !Preview {
        if (!std.mem.eql(u8, change.scope, self.scope)) return error.RepositoryMismatch;
        if (change.edits.len == 0 or change.edits.len > max_edits) return error.InvalidEditBatch;
        if (try self.ctx.generation() != change.generation) return error.StaleGeneration;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var candidates: std.ArrayList(Candidate) = .empty;
        errdefer for (candidates.items) |item| item.parent.dir.close(self.io);
        for (change.edits) |edit| {
            try self.authorize(edit.path, true);
            for (candidates.items) |other| if (std.mem.eql(u8, edit.path, other.edit.path)) return error.DuplicatePath;
            const dir = try self.parent(a, edit.path);
            var transferred = false;
            defer if (!transferred) dir.dir.close(self.io);
            var before = try self.readCurrent(a, dir);
            const file = try fs.openRegular(dir.dir, self.io, dir.name);
            defer file.close(self.io);
            const writable = try fs.writableMetadata(file, self.io);
            if (!fs.same(before.meta, writable)) return error.FileChanged;
            for (candidates.items) |other| if (std.mem.eql(u8, before.meta.identity.text(), other.before.meta.identity.text())) return error.DuplicateTarget;
            if (try self.ctx.database.number("SELECT count(*) FROM repo_files f JOIN repo_versions v ON v.file_id=f.id AND v.version=f.version WHERE f.id=? AND f.version=? AND f.active=1 AND f.path=? AND v.hash=? AND f.identity=? AND v.permissions=? AND v.metadata=?;", &.{ .{ .int = edit.ref.id }, .{ .int = edit.ref.version }, .{ .text = edit.path }, .{ .blob = &before.hash }, .{ .text = before.meta.identity.text() }, .{ .int = before.meta.stat.permissions.toMode() }, .{ .blob = &before.metadata_hash } }) != 1) return error.StaleFile;
            before.ref = edit.ref;
            try rejectSecret(secret, before.body);
            const after = try replace(a, before.body, edit.replacements);
            try rejectSecret(secret, after);
            var hash: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(after, &hash, .{});
            if (std.mem.eql(u8, &before.hash, &hash)) return error.NoChange;
            var random: [16]u8 = undefined;
            self.io.random(&random);
            const recovery = try std.fmt.allocPrintSentinel(a, ".zerorepeat-edit-{s}", .{std.fmt.bytesToHex(random, .lower)}, 0);
            try candidates.append(a, .{ .edit = edit, .parent = dir, .before = before, .after = after, .after_hash = hash, .recovery = recovery });
            transferred = true;
        }
        return .{ .arena = arena, .candidates = try candidates.toOwnedSlice(a) };
    }

    /// Once intent is durable, every failure is uncertain and must not be replayed.
    pub fn apply(self: *Repository, allocator: Allocator, change: ChangeSet, secret: ?[]const u8) !i64 {
        var plan = try self.preview(allocator, change, secret);
        defer plan.deinit(self.io);
        try self.ctx.database.exec("BEGIN IMMEDIATE;");
        errdefer self.ctx.database.exec("ROLLBACK;") catch {};
        if (try self.ctx.generation() != change.generation) return error.StaleGeneration;
        if (try self.ctx.database.number("SELECT count(*) FROM edit_batches WHERE state IN('planned','publishing','attention');", &.{}) != 0) return error.EditNeedsReview;
        if (change.action_id) |action| if (try self.ctx.database.number("SELECT count(*) FROM actions a JOIN model_requests r ON r.id=a.request_id JOIN tasks t ON t.id=r.task_id WHERE a.id=? AND a.phase='started' AND a.name='patch' AND t.state='running';", &.{.{ .int = action }}) != 1) return error.ActionNotRunning;
        try self.ctx.database.run("INSERT INTO edit_batches(generation,state,undo_of,action_id) VALUES(?,'planned',?,?);", &.{ .{ .int = change.generation }, if (change.undo_of) |id| .{ .int = id } else .null, if (change.action_id) |id| .{ .int = id } else .null });
        const batch = try self.ctx.database.number("SELECT last_insert_rowid();", &.{});
        for (plan.candidates, 0..) |item, position| {
            _ = try self.ctx.putBlob(item.after);
            try self.ctx.database.run("INSERT INTO edit_entries(batch_id,position,file_id,base_version,old_hash,new_hash,recovery_name,parent_identity,state) VALUES(?,?,?,?,?,?,?,?,'planned');", &.{ .{ .int = batch }, .{ .int = @intCast(position) }, .{ .int = item.before.ref.id }, .{ .int = item.before.ref.version }, .{ .blob = &item.before.hash }, .{ .blob = &item.after_hash }, .{ .text = item.recovery }, .{ .text = item.parent.identity.text() } });
        }
        try self.ctx.database.exec("COMMIT;");
        self.publish(allocator, batch, &plan, change.generation) catch |err| {
            if (self.ctx.database.inTransaction()) self.ctx.database.exec("ROLLBACK;") catch return error.EditJournalUnavailable;
            self.ctx.database.run("UPDATE edit_batches SET state='attention',diagnostic=? WHERE id=?;", &.{ .{ .text = @errorName(err) }, .{ .int = batch } }) catch return error.EditJournalUnavailable;
            return error.EditOutcomeUncertain;
        };
        return batch;
    }

    fn publish(self: *Repository, allocator: Allocator, batch: i64, plan: *const Preview, initial_generation: i64) !void {
        for (plan.candidates, 0..) |item, position| {
            const stage = try item.parent.dir.createFile(self.io, item.recovery, .{ .exclusive = true, .read = true, .permissions = .fromMode(0o600) });
            defer stage.close(self.io);
            const source = try fs.openRegular(item.parent.dir, self.io, item.parent.name);
            defer source.close(self.io);
            try fs.copyMetadata(allocator, self.io, source, stage);
            if (!std.mem.eql(u8, &(try fs.signature(allocator, self.io, source)), &item.before.metadata_hash)) return error.FileChanged;
            try stage.writePositionalAll(self.io, item.after, 0);
            try fs.syncFile(stage, self.io);
            try fs.syncDirectory(item.parent.dir, self.io);
            const id = (try fs.metadata(stage, self.io)).identity;
            try self.ctx.database.run("UPDATE edit_entries SET state='staged',stage_identity=? WHERE batch_id=? AND position=?;", &.{ .{ .text = id.text() }, .{ .int = batch }, .{ .int = @intCast(position) } });
            try fault(.staged, self.io, item);
        }
        var generation = initial_generation;
        for (plan.candidates, 0..) |item, position| {
            try self.io.checkCancel();
            try self.ctx.database.exec("BEGIN IMMEDIATE;");
            if (try self.ctx.generation() != generation) return error.StaleGeneration;
            try self.checkParent(allocator, item);
            var before = try self.readCurrent(allocator, item.parent);
            defer before.deinit(allocator);
            if (!fs.same(before.meta, item.before.meta) or !std.mem.eql(u8, &before.hash, &item.before.hash) or !std.mem.eql(u8, &before.metadata_hash, &item.before.metadata_hash)) return error.StaleFile;
            try self.ctx.database.run("UPDATE edit_batches SET state='publishing' WHERE id=?;", &.{.{ .int = batch }});
            try self.ctx.database.run("UPDATE edit_entries SET state='started' WHERE batch_id=? AND position=?;", &.{ .{ .int = batch }, .{ .int = @intCast(position) } });
            try self.ctx.database.exec("COMMIT;");
            try fault(.before_exchange, self.io, item);
            try fs.exchange(item.parent.dir, item.parent.name, item.recovery);
            try fs.syncDirectory(item.parent.dir, self.io);
            try fault(.after_exchange, self.io, item);
            const displaced_file = try fs.openRegular(item.parent.dir, self.io, item.recovery);
            defer displaced_file.close(self.io);
            const displaced = try fs.read(allocator, self.io, displaced_file, max_file_bytes);
            defer allocator.free(displaced.body);
            _ = try fs.writableMetadata(displaced_file, self.io);
            const displaced_metadata = try fs.signature(allocator, self.io, displaced_file);
            var after = try self.readCurrent(allocator, item.parent);
            defer after.deinit(allocator);
            if (!std.mem.eql(u8, displaced.body, item.before.body) or !std.mem.eql(u8, displaced.meta.identity.text(), item.before.meta.identity.text()) or
                displaced.meta.stat.permissions.toMode() != item.before.meta.stat.permissions.toMode() or displaced.meta.uid != item.before.meta.uid or displaced.meta.gid != item.before.meta.gid or
                !std.mem.eql(u8, &after.hash, &item.after_hash) or !std.mem.eql(u8, &displaced_metadata, &item.before.metadata_hash) or !std.mem.eql(u8, &after.metadata_hash, &item.before.metadata_hash)) return error.ConcurrentEditPreserved;
            var entry = try self.ctx.database.statement("SELECT stage_identity FROM edit_entries WHERE batch_id=? AND position=?;", &.{ .{ .int = batch }, .{ .int = @intCast(position) } });
            defer entry.deinit();
            if (!try entry.step() or !std.mem.eql(u8, entry.text(0), after.meta.identity.text())) return error.ConcurrentEditPreserved;
            try self.checkParent(allocator, item);
            try fault(.before_receipt, self.io, item);
            try self.ctx.database.exec("BEGIN IMMEDIATE;");
            if (try self.ctx.generation() != generation) return error.StaleGeneration;
            const ref: Ref = .{ .id = item.before.ref.id, .version = std.math.add(i64, item.before.ref.version, 1) catch return error.VersionOverflow };
            try self.insertVersion(ref, after.hash, after.meta, after.metadata_hash);
            try self.ctx.database.run("UPDATE repo_files SET version=?,identity=? WHERE id=?;", &.{ .{ .int = ref.version }, .{ .text = after.meta.identity.text() }, .{ .int = ref.id } });
            try self.ctx.database.run("UPDATE edit_entries SET state='applied',result_version=? WHERE batch_id=? AND position=?;", &.{ .{ .int = ref.version }, .{ .int = batch }, .{ .int = @intCast(position) } });
            try self.ctx.advanceGeneration();
            generation = try self.ctx.generation();
            try self.ctx.database.exec("COMMIT;");
        }
        try self.ctx.database.run("UPDATE edit_batches SET state='applied' WHERE id=?;", &.{.{ .int = batch }});
    }

    fn checkParent(self: *Repository, allocator: Allocator, item: Candidate) !void {
        const observed = try self.parent(allocator, item.edit.path);
        defer allocator.free(observed.name);
        defer observed.dir.close(self.io);
        if (!std.mem.eql(u8, observed.identity.text(), item.parent.identity.text())) return error.ParentMoved;
    }

    /// Inspection acknowledgement only: no filesystem action or retry occurs.
    pub fn acknowledge(self: *Repository, batch: i64) !void {
        try self.ctx.database.run("UPDATE edit_batches SET state='reviewed' WHERE id=? AND state='attention';", &.{.{ .int = batch }});
        if (try self.ctx.database.number("SELECT changes();", &.{}) != 1) return error.EditNeedsReview;
    }

    /// The host must first establish that the previous editor process has exited.
    pub fn recoverAfterOwnerExit(self: *Repository) !void {
        try self.ctx.database.exec("BEGIN IMMEDIATE;");
        errdefer self.ctx.database.exec("ROLLBACK;") catch {};
        try self.ctx.database.exec("UPDATE edit_batches SET state='attention',diagnostic='OwnerExited' WHERE state IN('planned','publishing');");
        if (try self.ctx.database.number("SELECT changes();", &.{}) > 0) try self.ctx.advanceGeneration();
        try self.ctx.database.exec("COMMIT;");
    }

    /// Undo is a new explicitly versioned edit, never a crash-recovery replay.
    pub fn undo(self: *Repository, allocator: Allocator, batch: i64, generation: i64, expected: []const Ref, secret: ?[]const u8) !i64 {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var edits: std.ArrayList(Edit) = .empty;
        var rows = try self.ctx.database.statement("SELECT f.id,f.path,e.old_hash FROM edit_entries e JOIN repo_files f ON f.id=e.file_id JOIN edit_batches b ON b.id=e.batch_id WHERE b.id=? AND b.state='applied' ORDER BY e.position;", &.{.{ .int = batch }});
        defer rows.deinit();
        while (try rows.step()) {
            const index = edits.items.len;
            if (index >= expected.len or expected[index].id != rows.int(0)) return error.StaleFile;
            const original = try self.ctx.readBlob(a, rows.blob(2));
            const current_hash = try self.ctx.database.statement("SELECT hash FROM repo_versions WHERE file_id=? AND version=?;", &.{ .{ .int = expected[index].id }, .{ .int = expected[index].version } });
            var current_row = current_hash;
            defer current_row.deinit();
            if (!try current_row.step()) return error.StaleFile;
            const current_body = try self.ctx.readBlob(a, current_row.blob(0));
            const replacements = try a.alloc(Replacement, 1);
            replacements[0] = .{ .start = 0, .end = current_body.len, .text = original };
            try edits.append(a, .{ .path = try a.dupe(u8, rows.text(1)), .ref = expected[index], .replacements = replacements });
        }
        if (edits.items.len != expected.len or edits.items.len == 0) return error.InvalidEditBatch;
        return self.apply(allocator, .{ .scope = self.scope, .generation = generation, .edits = edits.items, .undo_of = batch }, secret);
    }
};

fn privateStorePath(root: []const u8, store: []const u8, relative: []const u8) bool {
    const start = if (std.mem.eql(u8, root, "/")) @as(usize, 1) else root.len + 1;
    if (store.len <= start or !std.mem.startsWith(u8, store, root) or (start != 1 and store[root.len] != '/')) return false;
    const private = store[start..];
    if (std.ascii.eqlIgnoreCase(private, relative)) return true;
    if (relative.len < private.len or !std.ascii.eqlIgnoreCase(relative[0..private.len], private)) return false;
    const suffix = relative[private.len..];
    return std.ascii.eqlIgnoreCase(suffix, "-wal") or std.ascii.eqlIgnoreCase(suffix, "-shm") or std.ascii.eqlIgnoreCase(suffix, "-journal");
}

fn fault(point: FaultPoint, _: Io, item: Candidate) !void {
    if (faults_enabled) if (fault_hook) |hook| try hook(point, item.parent.dir, item.parent.name, item.recovery);
}

pub fn rejectSecret(secret: ?[]const u8, body: []const u8) !void {
    if (secret) |value| if (value.len == 0 or std.mem.indexOf(u8, body, value) != null) return error.SensitiveData;
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or !std.unicode.utf8ValidateSlice(path)) return error.InvalidRepositoryPath;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\') return error.InvalidRepositoryPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidRepositoryPath;
        if (std.ascii.eqlIgnoreCase(part, ".git") or std.ascii.eqlIgnoreCase(part, ".zerorepeat") or std.mem.startsWith(u8, part, ".zerorepeat-edit-")) return error.ReservedRepositoryPath;
    }
}

pub fn replace(allocator: Allocator, before: []const u8, changes: []const Replacement) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(before) or changes.len == 0 or changes.len > max_replacements) return error.InvalidReplacement;
    var size = before.len;
    var cursor: usize = 0;
    for (changes, 0..) |change, index| {
        if (change.start < cursor or change.start > change.end or change.end > before.len or
            (index > 0 and change.start == cursor and changes[index - 1].start == cursor) or
            !boundary(before, change.start) or !boundary(before, change.end) or !std.unicode.utf8ValidateSlice(change.text)) return error.InvalidReplacement;
        size -= change.end - change.start;
        size = std.math.add(usize, size, change.text.len) catch return error.FileTooLarge;
        if (size > max_file_bytes) return error.FileTooLarge;
        cursor = change.end;
    }
    const result = try allocator.alloc(u8, size);
    var writer: Io.Writer = .fixed(result);
    cursor = 0;
    for (changes) |change| {
        writer.writeAll(before[cursor..change.start]) catch unreachable;
        writer.writeAll(change.text) catch unreachable;
        cursor = change.end;
    }
    writer.writeAll(before[cursor..]) catch unreachable;
    std.debug.assert(writer.end == size);
    return result;
}

fn boundary(bytes: []const u8, offset: usize) bool {
    return offset == 0 or offset == bytes.len or bytes[offset] & 0xc0 != 0x80;
}
