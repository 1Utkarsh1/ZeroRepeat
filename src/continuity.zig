const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const header = "id\tkind\trequirement\tstatus\tdisposition\towner\tsource_revision\tevidence\tacceptance";
const documents = [_][]const u8{ "docs/PLAN.md", "docs/STATE.md", "docs/TASKS.md", "docs/LOG.md" };
const max_document_bytes = 2 * 1024 * 1024;
const log_tail_bytes = 16 * 1024;
const baseline_groups = [_]struct { prefix: []const u8, count: usize }{
    .{ .prefix = "ZR", .count = 18 },
    .{ .prefix = "BC", .count = 22 },
    .{ .prefix = "MEM", .count = 4 },
    .{ .prefix = "REF", .count = 26 },
};

fn baselineKind(prefix: []const u8, number: usize) []const u8 {
    if (std.mem.eql(u8, prefix, "REF")) return "reference";
    if (std.mem.eql(u8, prefix, "BC")) return switch (number) {
        17, 18, 20 => "optional",
        22 => "reference",
        else => "required",
    };
    return "required";
}

pub const Report = struct {
    rows: usize = 0,
    required: usize = 0,
    complete: usize = 0,
    required_open: usize = 0,
    reference_open: usize = 0,
};

const Row = struct {
    id: []const u8,
    kind: []const u8,
    requirement: []const u8,
    status: []const u8,
    disposition: []const u8,
    owner: []const u8,
    source_revision: []const u8,
    evidence: []const u8,
    acceptance: []const u8,
};

fn meaningful(text: []const u8) bool {
    return text.len != 0 and !std.ascii.eqlIgnoreCase(text, "pending") and
        !std.ascii.eqlIgnoreCase(text, "none") and !std.mem.eql(u8, text, "-");
}

fn parseRow(line: []const u8) !Row {
    var fields: [9][]const u8 = undefined;
    var split = std.mem.splitScalar(u8, line, '\t');
    for (&fields) |*field| field.* = std.mem.trim(u8, split.next() orelse return error.InvalidCoverageRow, " \r");
    if (split.next() != null) return error.InvalidCoverageRow;
    return .{ .id = fields[0], .kind = fields[1], .requirement = fields[2], .status = fields[3], .disposition = fields[4], .owner = fields[5], .source_revision = fields[6], .evidence = fields[7], .acceptance = fields[8] };
}

/// Checks claim structure, not the truth of tests recorded in evidence artifacts.
pub fn validateTable(allocator: Allocator, table: []const u8, release: bool, writer: *Io.Writer) !Report {
    var lines = std.mem.splitScalar(u8, table, '\n');
    const first = std.mem.trimEnd(u8, lines.next() orelse return error.InvalidCoverageHeader, "\r");
    if (!std.mem.eql(u8, first, header)) return error.InvalidCoverageHeader;
    var ids = std.StringHashMap([]const u8).init(allocator);
    defer ids.deinit();
    var report: Report = .{};
    var line_number: usize = 1;
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const row = parseRow(line) catch |err| {
            try writer.print("coverage line {d}: expected nine TSV fields\n", .{line_number});
            return err;
        };
        if (!meaningful(row.id) or !meaningful(row.requirement) or !meaningful(row.owner) or !meaningful(row.acceptance)) {
            try writer.print("coverage line {d}: id, requirement, owner and acceptance are required\n", .{line_number});
            return error.InvalidCoverageRow;
        }
        if (!oneOf(row.kind, &.{ "required", "reference", "optional" }) or
            !oneOf(row.status, &.{ "pending", "in_progress", "complete", "deferred" }) or
            !oneOf(row.disposition, &.{ "implement", "existing", "defer", "investigate" }))
        {
            try writer.print("coverage line {d}: unknown kind, status or disposition\n", .{line_number});
            return error.InvalidCoverageRow;
        }
        const entry = try ids.getOrPut(row.id);
        if (entry.found_existing) {
            try writer.print("coverage line {d}: duplicate id {s}\n", .{ line_number, row.id });
            return error.DuplicateCoverageId;
        }
        entry.value_ptr.* = row.kind;
        const required = std.mem.eql(u8, row.kind, "required");
        const complete = std.mem.eql(u8, row.status, "complete");
        if (required and (std.mem.eql(u8, row.status, "deferred") or std.mem.eql(u8, row.disposition, "defer"))) {
            try writer.print("coverage {s}: a required release feature cannot be deferred\n", .{row.id});
            return error.RequiredFeatureDeferred;
        }
        if (complete and (!meaningful(row.evidence) or !oneOf(row.disposition, &.{ "implement", "existing" }))) {
            try writer.print("coverage {s}: completion requires evidence and an implemented disposition\n", .{row.id});
            return error.CompletionEvidenceMissing;
        }
        if (complete and (!meaningful(row.source_revision) or std.mem.eql(u8, row.source_revision, "not_pinned"))) return error.CompletionRevisionMissing;
        report.rows += 1;
        report.required += @intFromBool(required);
        report.complete += @intFromBool(complete);
        report.required_open += @intFromBool(required and !complete);
        report.reference_open += @intFromBool(std.mem.eql(u8, row.kind, "reference") and !complete and !std.mem.eql(u8, row.status, "deferred"));
    }
    for (baseline_groups) |group| for (1..group.count + 1) |number| {
        var id_buffer: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "{s}-{d:0>2}", .{ group.prefix, number });
        const kind = ids.get(id) orelse {
            try writer.print("coverage: missing baseline contract {s}\n", .{id});
            return error.CoreRequirementMissing;
        };
        if (!std.mem.eql(u8, kind, baselineKind(group.prefix, number))) return error.BaselineKindChanged;
    };
    try writer.print("Coverage: {d} rows, {d} required, {d} complete, {d} required open, {d} reference audits open.\n", .{ report.rows, report.required, report.complete, report.required_open, report.reference_open });
    if (release and (report.required_open != 0 or report.reference_open != 0)) return error.ReleaseIncomplete;
    return report;
}

fn oneOf(text: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, text, choice)) return true;
    return false;
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| if (segment.len == 0 or std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".")) return false;
    return true;
}

fn evidenceFiles(io: Io, root: Io.Dir, table: []const u8, writer: *Io.Writer) !void {
    var lines = std.mem.splitScalar(u8, table, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const row = try parseRow(line);
        if (!std.mem.eql(u8, row.status, "complete")) continue;
        var entries = std.mem.splitScalar(u8, row.evidence, ';');
        var local_artifacts: usize = 0;
        while (entries.next()) |item| {
            const path = std.mem.trim(u8, item, " ");
            if (std.mem.startsWith(u8, path, "https://")) continue;
            if (!safeRelativePath(path)) return error.InvalidEvidencePath;
            const stat = root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
                try writer.print("coverage {s}: missing evidence file {s} ({s})\n", .{ row.id, path, @errorName(err) });
                return error.CompletionEvidenceMissing;
            };
            if (stat.kind != .file or stat.size == 0) return error.CompletionEvidenceMissing;
            local_artifacts += 1;
        }
        if (std.mem.eql(u8, row.kind, "required") and local_artifacts == 0) {
            try writer.print("coverage {s}: a required implementation needs a local evidence artifact\n", .{row.id});
            return error.CompletionEvidenceMissing;
        }
    }
}

pub fn check(allocator: Allocator, io: Io, root_path: []const u8, release: bool, writer: *Io.Writer) !void {
    var root = try Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    for (documents) |path| {
        const stat = root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
            try writer.print("continuity: missing {s} ({s})\n", .{ path, @errorName(err) });
            return error.ContinuityDocumentMissing;
        };
        if (stat.kind != .file or stat.size == 0) return error.ContinuityDocumentMissing;
    }
    const table = try root.readFileAlloc(io, "docs/COVERAGE.tsv", allocator, .limited(max_document_bytes));
    defer allocator.free(table);
    _ = try validateTable(allocator, table, release, writer);
    try evidenceFiles(io, root, table, writer);
    try writer.writeAll("Evidence paths checked; recorded results still require human/runtime verification.\n");
}

pub fn appendLog(allocator: Allocator, io: Io, root_path: []const u8, title: []const u8, text: []const u8) !void {
    if (std.mem.trim(u8, title, " \r\n").len == 0 or std.mem.indexOfAny(u8, title, "\r\n") != null) return error.InvalidLogTitle;
    var root = try Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    var file = try root.openFile(io, "docs/LOG.md", .{ .mode = .write_only, .lock = .exclusive, .follow_symlinks = false });
    defer file.close(io);
    const seconds = Io.Timestamp.now(io, .real).toSeconds();
    if (seconds < 0) return error.InvalidTimestamp;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    const record = try std.fmt.allocPrint(allocator, "\n## {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC — {s}\n\n{s}\n", .{
        year_day.year,          @backingInt(month_day.month), @as(u8, month_day.day_index) + 1,
        time.getHoursIntoDay(), time.getMinutesIntoHour(),    time.getSecondsIntoMinute(),
        title,                  text,
    });
    defer allocator.free(record);
    try file.writePositionalAll(io, record, try file.length(io));
    try file.sync(io);
}

/// A bounded re-entry aid; the full PLAN remains authoritative.
pub fn render(allocator: Allocator, io: Io, root_path: []const u8, writer: *Io.Writer) !void {
    var root = try Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    try writer.writeAll("Read AGENTS.md and docs/PLAN.md for the complete release contract. This context is a re-entry aid; inspect current Git/files/tests before trusting old status.\n\n");
    for ([_][]const u8{ "docs/STATE.md", "docs/TASKS.md" }) |path| {
        const content = try root.readFileAlloc(io, path, allocator, .limited(max_document_bytes));
        defer allocator.free(content);
        try writer.print("--- {s} ---\n{s}\n", .{ path, content });
    }
    var log = try root.openFile(io, "docs/LOG.md", .{});
    defer log.close(io);
    const size = try log.length(io);
    const offset = size -| log_tail_bytes;
    const tail = try allocator.alloc(u8, @intCast(@min(size, log_tail_bytes)));
    defer allocator.free(tail);
    const read = try log.readPositionalAll(io, tail, offset);
    var start: usize = 0;
    if (offset != 0) {
        if (std.mem.indexOfScalar(u8, tail[0..read], '\n')) |newline| start = newline + 1;
    }
    try writer.print("--- docs/LOG.md (last <= {d} bytes) ---\n{s}\n", .{ log_tail_bytes, tail[start..read] });
}

fn sampleTable(allocator: Allocator, extra: []const u8, complete: bool) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{s}\n", .{header});
    for (baseline_groups) |group| for (1..group.count + 1) |number| {
        try out.writer.print("{s}-{d:0>2}\t{s}\tfeature\t{s}\timplement\tcore\tlocal\t{s}\ttest feature\n", .{ group.prefix, number, baselineKind(group.prefix, number), if (complete) "complete" else "pending", if (complete) "docs/evidence.md" else "-" });
    };
    try out.writer.writeAll(extra);
    return out.toOwnedSlice();
}

test "audit retains pending required work and release rejects it" {
    const a = std.testing.allocator;
    const table = try sampleTable(a, "", false);
    defer a.free(table);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const report = try validateTable(a, table, false, &out.writer);
    try std.testing.expectEqual(@as(usize, 40), report.required_open);
    try std.testing.expectError(error.ReleaseIncomplete, validateTable(a, table, true, &out.writer));
}

test "duplicates and missing core contracts are rejected" {
    const a = std.testing.allocator;
    const table = try sampleTable(a, "ZR-01\trequired\tduplicate\tpending\timplement\tcore\t-\t-\ttest\n", false);
    defer a.free(table);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expectError(error.DuplicateCoverageId, validateTable(a, table, false, &out.writer));
    try std.testing.expectError(error.CoreRequirementMissing, validateTable(a, header ++ "\n", false, &out.writer));
}

test "all original feature and reference IDs survive re-entry and cannot change kind" {
    const a = std.testing.allocator;
    const table = try sampleTable(a, "", false);
    defer a.free(table);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (baseline_groups) |group| for (1..group.count + 1) |number| {
        const marker = try std.fmt.allocPrint(a, "\n{s}-{d:0>2}\t", .{ group.prefix, number });
        defer a.free(marker);
        const start = (std.mem.indexOf(u8, table, marker) orelse unreachable) + 1;
        const end = start + (std.mem.indexOfScalar(u8, table[start..], '\n') orelse unreachable) + 1;
        const removed = try std.mem.concat(a, u8, &.{ table[0..start], table[end..] });
        defer a.free(removed);
        try std.testing.expectError(error.CoreRequirementMissing, validateTable(a, removed, false, &out.writer));
    };
    const demoted = try std.mem.replaceOwned(u8, a, table, "MEM-01\trequired", "MEM-01\toptional");
    defer a.free(demoted);
    try std.testing.expectError(error.BaselineKindChanged, validateTable(a, demoted, false, &out.writer));
}

test "release also requires reference audits and completion pins a source revision" {
    const a = std.testing.allocator;
    const table = try sampleTable(a, "", true);
    defer a.free(table);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    _ = try validateTable(a, table, true, &out.writer);
    const unfinished = try std.mem.replaceOwned(u8, a, table, "REF-01\treference\tfeature\tcomplete", "REF-01\treference\tfeature\tpending");
    defer a.free(unfinished);
    try std.testing.expectError(error.ReleaseIncomplete, validateTable(a, unfinished, true, &out.writer));
    const unpinned = try std.mem.replaceOwned(u8, a, table, "\tlocal\t", "\tnot_pinned\t");
    defer a.free(unpinned);
    try std.testing.expectError(error.CompletionRevisionMissing, validateTable(a, unpinned, false, &out.writer));
}

test "completion requires evidence and required work cannot be deferred" {
    const a = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const missing = try sampleTable(a, "EXTRA-01\trequired\tmemory\tcomplete\timplement\tcontinuity\tlocal\t-\ttest\n", false);
    defer a.free(missing);
    try std.testing.expectError(error.CompletionEvidenceMissing, validateTable(a, missing, false, &out.writer));
    const deferred = try sampleTable(a, "EXTRA-01\trequired\tmemory\tdeferred\tdefer\tcontinuity\tlocal\t-\ttest\n", false);
    defer a.free(deferred);
    try std.testing.expectError(error.RequiredFeatureDeferred, validateTable(a, deferred, false, &out.writer));
}

test "unknown state, malformed header and bad field count fail" {
    const a = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expectError(error.InvalidCoverageHeader, validateTable(a, "id\tstatus\n", false, &out.writer));
    const bad = try sampleTable(a, "MEM-01\trequired\tmemory\tgreen\timplement\tcontinuity\tlocal\t-\ttest\n", false);
    defer a.free(bad);
    try std.testing.expectError(error.InvalidCoverageRow, validateTable(a, bad, false, &out.writer));
    const short = try sampleTable(a, "MEM-01\trequired\n", false);
    defer a.free(short);
    try std.testing.expectError(error.InvalidCoverageRow, validateTable(a, short, false, &out.writer));
}

test "evidence paths cannot escape the project" {
    try std.testing.expect(safeRelativePath("docs/evidence/test.md"));
    for ([_][]const u8{ "../outside", "/absolute", "docs/../outside", "docs\\outside", "docs//file" }) |path| try std.testing.expect(!safeRelativePath(path));
}

test "local completion evidence must exist and be nonempty" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const table = try sampleTable(a, "", true);
    defer a.free(table);
    try std.testing.expectError(error.CompletionEvidenceMissing, evidenceFiles(std.testing.io, temp.dir, table, &out.writer));
    try temp.dir.createDirPath(std.testing.io, "docs");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "docs/evidence.md", .data = "Observed command and results.\n" });
    try evidenceFiles(std.testing.io, temp.dir, table, &out.writer);
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "docs/evidence.md", .data = "" });
    try std.testing.expectError(error.CompletionEvidenceMissing, evidenceFiles(std.testing.io, temp.dir, table, &out.writer));
}

test "log append preserves old bytes and re-entry includes bounded log tail" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "docs");
    for (documents) |path| try temp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "original\n" });
    const root_path = try std.fs.path.join(a, &.{ std.testing.TmpDir.parent_dir_path, &temp.sub_path });
    defer a.free(root_path);
    try appendLog(a, std.testing.io, root_path, "start", "Concrete next action.");
    const content = try temp.dir.readFileAlloc(std.testing.io, "docs/LOG.md", a, .limited(1024));
    defer a.free(content);
    try std.testing.expect(std.mem.startsWith(u8, content, "original\n"));
    try std.testing.expect(std.mem.indexOf(u8, content, "UTC — start") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Concrete next action.") != null);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try render(a, std.testing.io, root_path, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "docs/PLAN.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Concrete next action.") != null);
    try std.testing.expectError(error.InvalidLogTitle, appendLog(a, std.testing.io, root_path, "bad\ntitle", "text"));
}

test "re-entry reads only the recent tail of a growing log" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "docs");
    for (documents) |path| try temp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "context\n" });
    var history: [40 * 1024]u8 = @splat('x');
    for (0..history.len / 80) |line| history[line * 80] = '\n';
    @memcpy(history[0..13], "OLD_SENTINEL\n");
    @memcpy(history[history.len - 17 ..], "\nRECENT_SENTINEL\n");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "docs/LOG.md", .data = &history });
    const root_path = try std.fs.path.join(a, &.{ std.testing.TmpDir.parent_dir_path, &temp.sub_path });
    defer a.free(root_path);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try render(a, std.testing.io, root_path, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "OLD_SENTINEL") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "RECENT_SENTINEL") != null);
    try std.testing.expect(out.written().len < log_tail_bytes + 1024);
}
